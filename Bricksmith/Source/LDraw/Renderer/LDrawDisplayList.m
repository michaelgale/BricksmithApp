//
// LDrawDisplayList.m
// Bricksmith
//
// Created by bsupnik on 11/12/12.
// Copyright 2012 __MyCompanyName__. All rights reserved.
//

#import "LDrawDisplayList.h"
#import "LDrawRenderer.h"
#import "LDrawBDPAllocator.h"
#import "LDrawShaderRenderer.h"
#import "MeshSmooth.h"
#import "GLMatrixMath.h"
#import OPEN_GL_HEADER
#import OPEN_GL_EXT_HEADER


// This forces quads to be subdivided into tris at creation.
// For unindexed geometry this is a loss - we end up pushing 50% more vertices for the quad data, which hurts vertex-bound big models.
// To revisit: once we are indexed, will quads vs tris be a wash?
#define ONLY_USE_TRIS     0

// This turns on normal smoothing.
#define WANT_SMOOTH       1

// This times smoothing of parts.
#define TIME_SMOOTHING    0

#if WANT_SMOOTH
static const GLuint *idx_null = NULL;
#endif

/*
 *
 * INSTANCING IMPLEMENTATION NOTES
 *
 * Instancing is just fancy talk for drawing one thing many times in some efficient way.  Instancing is a good fit for BrickSmith
 * because we draw the same bricks over and over and over again.
 *
 * When we instance, we identify the 'per instance' data - that is, data that is different for every instance.  In the case of
 * BrickSmith, the current/compliment color and transform are per instance data; the mesh and non-meta colors of the mesh are invariant.
 *
 * (As an example, when drawing the plate with red wheels, the red color of the wheels and the shape of the part are invariant;
 * the current color used for the plate and the location of the whole part are per-instance data.)
 *
 * "Attribute" instancing means changing the instance data by changing GL attributes.  The theory is that the GL can change attribute
 * data faster than uniform data, so changing the current location and color via attributes should be quite cheap.
 *
 * "Hardware" instancing implies using one of the native GL instancing APIs like GL_ARB_instanced_arrays.  In this case, we put our instance
 * attributes into their own VBO (of consecutive interleaved "instances"), give the GL the base pointer and tell it to draw N copies of
 * our mesh, using the instanced data from the VBO.
 *
 * When hardware instancing works right, it can lead to much higher throughput than attributes, which are faster in turn than uniforms.
 * In practice, this is hugely dependent on what driver we're running on.
 *
 * DEFERRING DRAWING FOR INSTANCING
 *
 * When a DL can be drawn via instancing (either attribute or hw) it is not drawn - it is saved on the session; when the session is
 * destroyed we draw out every DL we have deferred, in order (e.g. all instances of one DL) to avoid swapping VBOs.
 *
 * During that deferred draw-out we either build a hw instance list or simply draw.
 *
 * DEFERRED DARWING FOR Z SORTING
 *
 * When a DL does not have to be drawn immediately and has translucency, we always try to save it to the sorted list.
 *
 * Then when the session is destroyed, we sort all of these "sort-deferred" DLs by their local origin and draw back to front.
 * This helps keep translucency looking good.
 *
 */

#define WANT_STATS                0

#define VERT_STRIDE               10           // Stride of our vertices - we always write X Y Z	NX NY NZ		R G B A
#define INST_CUTOFF               5            // Minimum instances to use hw case, which has higher overhead to set up.
#define INST_MAX_COUNT            (1024 * 128) // Maximum instances to write per draw before going to immediate mode - avoids unbounded VRAM use.
#define INST_RING_BUFFER_COUNT    4            // Number of VBOs to rotate for hw instancing - doesn't actually help, it turns out.
#define MODE_FOR_INST_STREAM      GL_DYNAMIC_STATIC // VBO mode for instancing.

enum
{
  dl_has_alpha     = 1, // At least one prim in this DL has translucency.
  dl_has_meta      = 2, // At least one prim in this DL uses a meta-color and thus MIGHT pick up translucency from parent state during draw.
  dl_has_tex       = 4, // At lesat one real texture is used.
  dl_needs_destroy = 8  // Destroy after drawing - ptr is only around because it is queued!
};


// ========== get_instance_cutoff =================================================
//
// Purpose:	Determine whether we can use hardware instancing.
//
// Notes:	Pre-DX10 Mac GPUs on older operating systems don't support instancing;
// This routine checks for the GL_ARB_instanced_arrays extension string,
// which will always be present since we are using legacy 2.1-style
// contexts. (If we go to the core profile we'll need to also look at the
// GL version.)
//
// If the hardware won't instance, we simply set the instancing min limit
// to an insanely high limit so that we never hit that case.
//
// ================================================================================
static int  get_instance_cutoff(void)
{
  static int has_instancing = -1;

  if (has_instancing == -1) {
    const GLubyte *ext_str = glGetString(GL_EXTENSIONS);
    if (strstr((const char *)ext_str, "GL_ARB_instanced_arrays") != NULL) {
      has_instancing = 1;
    }
    else {
      has_instancing = 0;
    }
  }
  return(has_instancing ? INST_CUTOFF : INT32_MAX);
}


static void copy_vec3(GLfloat d[3], const GLfloat s[3])
{
  d[0] = s[0]; d[1] = s[1]; d[2] = s[2];
}


static void copy_vec4(GLfloat d[4], const GLfloat s[4])
{
  d[0] = s[0]; d[1] = s[1]; d[2] = s[2]; d[3] = s[3];
}


static GLuint inst_vbo_ring[INST_RING_BUFFER_COUNT] = { 0 };
static int    inst_ring_last = 0;


// ========== DISPLAY LIST DATA STRUCTURES ========================================

// Per-texture mesh info.  Texture spec plus the offset/count into a single VBO for the lines, tris and quads to draw.
// This is used in a finished DL.
struct LDrawDLPerTex {
  struct LDrawTextureSpec spec;
  GLuint                  line_off;
  GLuint                  line_count;
  GLuint                  tri_off;
  GLuint                  tri_count;
  GLuint                  quad_off;
  GLuint                  quad_count;
};

// DL draw instance: this stores one request to draw an un-textured DL for intsancing.
// current color/compliment color, transform, and a next ptr to build a linked list.
struct LDrawDLInstance {
  struct LDrawDLInstance *next;
  GLfloat                color[4];
  GLfloat                comp[4];
  GLfloat                transform[16];
};

// A single DL.  A few notes on book-keeping:
// DLs that are drawn deferred+instanced in a session sit in a linked list attached to the session - that's what
// next_dl is for.
// Such DLs also have an instance linked list (instance head/tail/count) for each place they should be drawn.
// All of those get cleared out when DL is not being used in a session.
struct LDrawDL {
  struct LDrawDL         *next_dl;       // Session "linked list of active dLs."
  struct LDrawDLInstance *instance_head; // Linked list of instances to draw.
  struct LDrawDLInstance *instance_tail;
  int                    instance_count;
  int                    flags;     // See flags defs above.
  GLuint                 geo_vbo;   // Single VBO containing all geometry in the DL.
#if WANT_SMOOTH
  GLuint                 idx_vbo;   // Single VBO containing all mesh indices.
#endif
  int                    tex_count; // Number of per-textures; untex case is always first if present.
  #if WANT_STATS
  int                    vrt_count;
#if WANT_SMOOTH
  int                    idx_count;
#endif
  #endif
  struct LDrawDLPerTex   texes[0];      // Variable size array of textures - DL is allocated larger as needed.
};

// ==========  SESSION DATA STRUCTURES ========================================

// We write all instancing info into a single huge VBO.  This avoids the need
// to constantly map/unmap our VBOs.  As we draw we use a variable sized array
// of "Segments" to track the instancing lists of each brick within the single
// huge instancing data buffer.  (The name is taken from "segment buffering" in
// GPU Gems 2.)
struct LDrawDLSegment {
  GLuint               geo_vbo; // VBO of the brick we are going to draw - contains the actual brick mesh.
#if WANT_SMOOTH
  GLuint               idx_vbo;
#endif
  struct LDrawDLPerTex *dl;           // Ptr to the per-tex info for that brick - only untexed bricks get instanced, so we only have one "per tex", by definition.
  float                *inst_base; // VBO-relative ptr to the instance data base in the instance VBO.
  int                  inst_count; // Number of instances startingat that offset.
};


// The sorted instance link is a 'full' instance (DL, color/comp, transform and texture) used for drawing DLs that are going to be Z sorted.
// Unlike the faster harder instancing, we keep tex state around because we might draw ANY DL (even a multitextured one) to get the Z sort
// right.
struct LDrawDLSortedInstanceLink {
  union {
    struct LDrawDLSortedInstanceLink *next; // DURING draw, we keep a linked list of these guys off of the session as we go.
    float eval;                             // At the end of draw, when we need to sort, we copy to a fixed size array and sort.
  };                                        // Maybe someday we could merge-sort the linked list, but use qsort for now to get shipped.
  struct  LDrawDL         *dl;
  struct LDrawTextureSpec spec;
  GLfloat                 color[4];
  GLfloat                 comp[4];
  GLfloat                 transform[16];
};


// One drawing session.
struct LDrawDLSession {
  #if WANT_STATS
  struct {
    int num_btch_imm;                 // Immediate drawing batches and verts
    int num_vert_imm;
    int num_btch_srt;                 // Sorted drawin batches and verts.
    int num_vert_srt;
    int num_btch_att;                 // Attribute instancing: batches, verts, instances
    int num_vert_att;
    int num_inst_att;
    int num_work_att;
    int num_btch_ins;                 // Hardare instancing: batches, verts, instances
    int num_vert_ins;
    int num_inst_ins;
    int num_work_ins;
  } stats;
  #endif
  struct LDrawBDP                  *alloc;    // Pool allocator for the session to rapidly save linked lists of 'stuff'.
  struct LDrawDL                   *dl_head;  // Linked list of all DLs that will be instance-drawn, with count.
  int                              dl_count;

  struct LDrawDLSortedInstanceLink *sorted_head;        // Linked list + count for DLs being drawn later to Z sort.
  int                              sort_count;

  GLfloat                          model_view[16]; // Model-view matrix, used to Z sort translucent objects.
  GLuint                           inst_ring; // If using more than one instancing buffer, this tells which one we use.
};


// ========== Dastructures for BUILDING a VBO ==============================


// As we build our VBO, we keep sets of vertices in a linked list.  When done
// we copy them into our VBO.  The linked list lets us add vertices a little
// at a time without expensive array resizes.  Since the linked list comes
// from a BDP locality is actually pretty good.
//
// Our link has a vertex count followed by VERT_STRIDE * vcount floats.
struct  LDrawDLBuilderVertexLink {
  struct LDrawDLBuilderVertexLink *next;
  int                             vcount;
  float                           data[0];
};


// Build structure per texture.  Textures are kept in a linked list during build
// since we don't know how many we will have.  Each type of drawing (line, tri, quad)
// is kept in a singly linked list of vertex links so that we can copy them consecutively when done.
struct LDrawDLBuilderPerTex {
  struct LDrawDLBuilderPerTex     *next;
  struct LDrawTextureSpec         spec;
  struct LDrawDLBuilderVertexLink *tri_head;
  struct LDrawDLBuilderVertexLink *tri_tail;
  struct LDrawDLBuilderVertexLink *quad_head;
  struct LDrawDLBuilderVertexLink *quad_tail;
  struct LDrawDLBuilderVertexLink *line_head;
  struct LDrawDLBuilderVertexLink *line_tail;
};


// LDrawBuilder: our build structure contains a BDP for temporary allocations and a
// linked list of textures (which in turn contain the geomtry.  So the entire
// structure just accumulates data in a set of linked lists, then cleans and saves
// the data carefully hwen we are done.
struct  LDrawDLBuilder {
  int                         flags;
  struct LDrawBDP             *alloc;
  struct LDrawDLBuilderPerTex *head;
  struct LDrawDLBuilderPerTex *cur;
};


// ========== LDrawDLBuilderCreate ================================================
//
// Purpose:	Create a new builder capable of accumulating DL data.
//
// ================================================================================

/* *INDENT-OFF* */
struct LDrawDLBuilder *LDrawDLBuilderCreate(void)
{
  // All allocs for the builder come from one pool.
  struct LDrawBDP *alloc = LDrawBDPCreate();

  // Build one tex struct now for the untextured set of meshes, which are the default state.
  struct LDrawDLBuilderPerTex *untex =
    (struct LDrawDLBuilderPerTex *)LDrawBDPAllocate(alloc, sizeof(struct LDrawDLBuilderPerTex));

  memset(untex, 0, sizeof(struct LDrawDLBuilderPerTex));

  struct LDrawDLBuilder *bld =
    (struct LDrawDLBuilder *)LDrawBDPAllocate(alloc, sizeof(struct LDrawDLBuilder));

  bld->cur = bld->head = untex;

  bld->alloc = alloc;
  bld->flags = 0;

  return(bld);
}// end LDrawDLBuilderCreate
/* *INDENT-ON* */


// ========== LDrawDLBuilderSetTex ================================================
//
// Purpose:	Change the current texture we are adding geometry to in a builder.
//
// ================================================================================
void LDrawDLBuilderSetTex(struct LDrawDLBuilder *ctx, struct LDrawTextureSpec *spec)
{
  struct LDrawDLBuilderPerTex *prev = ctx->head;

  // Walk "cur" down our texture list, stopping if we have a hit.
  for (ctx->cur = ctx->head; ctx->cur; ctx->cur = ctx->cur->next) {
    if (memcmp(spec, &ctx->cur->spec, sizeof(struct LDrawTextureSpec)) == 0) {
      break;
    }
    prev = ctx->cur;
  }

  if (ctx->cur == NULL) {
    // If we get here, we have never seen this texture before in this builder and
    // we need to allocate a new per-texture chunk of build state.
    struct LDrawDLBuilderPerTex *new_tex =
      (struct LDrawDLBuilderPerTex *)LDrawBDPAllocate(ctx->alloc,
                                                      sizeof(struct LDrawDLBuilderPerTex));
    memset(new_tex, 0, sizeof(struct LDrawDLBuilderPerTex));
    memcpy(&new_tex->spec, spec, sizeof(struct LDrawTextureSpec));
    prev->next = new_tex;
    ctx->cur   = new_tex;
  }
}// end LDrawDLBuilderSetTex


// ========== LDrawDLBuilderAddTri ================================================
//
// Purpose: Add one triangle to our DL using the current texture.
//
// Notes:	This routine 'sniffs' the alpha as it goes by and keeps the DL flags
// correct - this is how a DL "knows" if it is translucent.
//
// We accumulate the tri by allocating a 3-vertex DL link and queueing it
// onto the triangle list for the current texture.
//
// ================================================================================
void LDrawDLBuilderAddTri(struct LDrawDLBuilder *ctx, const GLfloat v[9], GLfloat n[3],
                          GLfloat c[4])
{
  // Alpha = 0 means meta color.  0 < Alpha < 1 means translucency.
  if (c[3] == 0.0f) { ctx->flags |= dl_has_meta; }
  else if (c[3] != 1.0f) { ctx->flags |= dl_has_alpha; }

  int i;
  struct LDrawDLBuilderVertexLink *nl = (struct LDrawDLBuilderVertexLink *)LDrawBDPAllocate(
    ctx->alloc,
    sizeof(
      struct
      LDrawDLBuilderVertexLink) + sizeof(
      GLfloat) * VERT_STRIDE *
    3);
  nl->next   = NULL;
  nl->vcount = 3;
  for (i = 0; i < 3; ++i) {
    copy_vec3(nl->data + VERT_STRIDE * i, v + i * 3); // Vertex data is per vertex.
    copy_vec3(nl->data + VERT_STRIDE * i + 3, n);     // But color and norm are for the whole tri, for now.  So we replicate it out to get
    copy_vec4(nl->data + VERT_STRIDE * i + 6, c);     // a uniform DL.
  }

  if (ctx->cur->tri_tail) {
    ctx->cur->tri_tail->next = nl;
    ctx->cur->tri_tail       = nl;
  }
  else {
    ctx->cur->tri_head = nl;
    ctx->cur->tri_tail = nl;
  }
}// end LDrawDLBuilderAddTri


// ========== LDrawDLBuilderAddQuad ===============================================
//
// Purpose:	Add one quad to the current DL builder in the current texture.
//
// ================================================================================
void LDrawDLBuilderAddQuad(struct LDrawDLBuilder *ctx, const GLfloat v[12], GLfloat n[3],
                           GLfloat c[4])
{
  if (c[3] == 0.0f) { ctx->flags |= dl_has_meta; }
  else if (c[3] != 1.0f) { ctx->flags |= dl_has_alpha; }

  #if ONLY_USE_TRIS
  int i;
  struct LDrawDLBuilderVertexLink *nl = (struct LDrawDLBuilderVertexLink *)LDrawBDPAllocate(
    ctx->alloc,
    sizeof(
      struct
      LDrawDLBuilderVertexLink) + sizeof(
      GLfloat) * VERT_STRIDE *
    3);
  nl->next   = NULL;
  nl->vcount = 3;
  for (i = 0; i < 3; ++i) {
    copy_vec3(nl->data + VERT_STRIDE * i, v + i * 3); // Vertex data is per vertex.
    copy_vec3(nl->data + VERT_STRIDE * i + 3, n);     // But color and norm are for the whole tri, for now.  So we replicate it out to get
    copy_vec4(nl->data + VERT_STRIDE * i + 6, c);     // a uniform DL.
  }

  if (ctx->cur->tri_tail) {
    ctx->cur->tri_tail->next = nl;
    ctx->cur->tri_tail       = nl;
  }
  else {
    ctx->cur->tri_head = nl;
    ctx->cur->tri_tail = nl;
  }


  nl =
    (struct LDrawDLBuilderVertexLink *)LDrawBDPAllocate(ctx->alloc,
                                                        sizeof(struct LDrawDLBuilderVertexLink) +
                                                        sizeof(GLfloat) * VERT_STRIDE * 3);
  nl->next   = NULL;
  nl->vcount = 3;
  for (i = 0; i < 3; ++i) {
    copy_vec3(nl->data + VERT_STRIDE * i + 3, n);  // But color and norm are for the whole tri, for now.  So we replicate it out to get
    copy_vec4(nl->data + VERT_STRIDE * i + 6, c);  // a uniform DL.
  }

  copy_vec3(nl->data + VERT_STRIDE * 0, v);     // Vertex data is per vertex.
  copy_vec3(nl->data + VERT_STRIDE * 1, v + 6); // Vertex data is per vertex.
  copy_vec3(nl->data + VERT_STRIDE * 2, v + 9); // Vertex data is per vertex.

  if (ctx->cur->tri_tail) {
    ctx->cur->tri_tail->next = nl;
    ctx->cur->tri_tail       = nl;
  }
  else {
    ctx->cur->tri_head = nl;
    ctx->cur->tri_tail = nl;
  }
  #else
  int i;
  struct LDrawDLBuilderVertexLink *nl = (struct LDrawDLBuilderVertexLink *)LDrawBDPAllocate(
    ctx->alloc, sizeof(struct LDrawDLBuilderVertexLink) + sizeof(GLfloat) * VERT_STRIDE * 4);
  nl->next   = NULL;
  nl->vcount = 4;
  for (i = 0; i < 4; ++i) {
    copy_vec3(nl->data + VERT_STRIDE * i, v + i * 3);
    copy_vec3(nl->data + VERT_STRIDE * i + 3, n);
    copy_vec4(nl->data + VERT_STRIDE * i + 6, c);
  }

  if (ctx->cur->quad_tail) {
    ctx->cur->quad_tail->next = nl;
    ctx->cur->quad_tail       = nl;
  }
  else {
    ctx->cur->quad_head = nl;
    ctx->cur->quad_tail = nl;
  }
  #endif
}// end LDrawDLBuilderAddQuad


// ========== LDrawDLBuilderAddLine ===============================================
//
// Purpose:	Add one line to the current DL builder in the current texture.
//
// ================================================================================
void LDrawDLBuilderAddLine(struct LDrawDLBuilder *ctx,
                           const GLfloat v[6],
                           GLfloat n[3],
                           GLfloat c[4])
{
  if (c[3] == 0.0f) { ctx->flags |= dl_has_meta; }
  else if (c[3] != 1.0f) { ctx->flags |= dl_has_alpha; }

  int i;
  struct LDrawDLBuilderVertexLink *nl = (struct LDrawDLBuilderVertexLink *)LDrawBDPAllocate(
    ctx->alloc,
    sizeof(
      struct
      LDrawDLBuilderVertexLink) + sizeof(
      GLfloat) * VERT_STRIDE *
    2);
  nl->next   = NULL;
  nl->vcount = 2;
  for (i = 0; i < 2; ++i) {
    copy_vec3(nl->data + VERT_STRIDE * i, v + i * 3);
    copy_vec3(nl->data + VERT_STRIDE * i + 3, n);
    copy_vec4(nl->data + VERT_STRIDE * i + 6, c);
  }

  if (ctx->cur->line_tail) {
    ctx->cur->line_tail->next = nl;
    ctx->cur->line_tail       = nl;
  }
  else {
    ctx->cur->line_head = nl;
    ctx->cur->line_tail = nl;
  }
}// end LDrawDLBuilderAddLine


// ========== LDrawDLBuilderFinish ================================================
//
// Purpose:	Take all of the accumulated data in a DL and bake it down to one
// final form.
//
// Notes:	The DL is, while being built, a series of linked lists in a BDP for
// speed.  The finished DL is a malloc'd block of memory, pre-sized to
// fit the DL perfectly, and one VBO.  So this routine does the counting,
// final allocations, and copying.
//
// ================================================================================

/* *INDENT-OFF* */
struct LDrawDL *LDrawDLBuilderFinish(struct LDrawDLBuilder *ctx)
{
#if WANT_SMOOTH
  #if TIME_SMOOTHING
  NSTimeInterval startTime = [NSDate timeIntervalSinceReferenceDate];
  #endif

  int total_texes = 0;
  int total_tris  = 0;
  int total_quads = 0;
  int total_lines = 0;


  struct LDrawDLBuilderVertexLink *l;
  struct LDrawDLBuilderPerTex     *s;

  // Count up the total vertices we will need, for VBO space, as well
  // as the total distinct non-empty textures.
  for (s = ctx->head; s; s = s->next) {
    if (s->tri_head || s->line_head || s->quad_head) {
      ++total_texes;
    }
    for (l = s->tri_head; l; l = l->next) {
      total_tris += l->vcount;
    }
    for (l = s->quad_head; l; l = l->next) {
      total_quads += l->vcount;
    }
    for (l = s->line_head; l; l = l->next) {
      total_lines += l->vcount;
    }
  }

  // No non-empty textures?  Bail out early - nuke our
  // context and get out.  Client code knows we get NO DL, rather than
  // an empty one.
  if (total_texes == 0) {
    LDrawBDPDestroy(ctx->alloc);
    return(NULL);
  }

  // Malloc DL structure with extra storage for variable-sized tex array.
  struct LDrawDL *dl = (struct LDrawDL *)malloc(sizeof(struct LDrawDL) + sizeof(
                                                  struct LDrawDLPerTex) * total_texes);

  // All per-session linked list ptrs start null.
  dl->next_dl        = NULL;
  dl->instance_head  = NULL;
  dl->instance_tail  = NULL;
  dl->instance_count = 0;

  dl->tex_count = total_texes;

  struct LDrawDLPerTex *cur_tex = dl->texes;
  dl->flags = ctx->flags;

  total_tris  /= 3;
  total_quads /= 4;
  total_lines /= 2;

  // We use one mesh for the entire DL, even if it has multiple textures.  We have to
  // do this because we wnat smoothing across triangles that do not share the same
  // texture.  (Key use case: minifig faces are part textured, part untextured.)
  //
  // So instead each face gets a texture ID (tid), which is an index that we will tie
  // to our texture list.  The mesh smoother remembers this and dumps out the tris in
  // tid order later.

  struct Mesh *M = create_mesh(total_tris, total_quads, total_lines);


  // Now: walk our building textures - for each non-empty one, we will copy it into
  // the tex array and push its vertices.
  int ti = 0;
  for (s = ctx->head; s; s = s->next) {
    if (s->tri_head == NULL && s->line_head == NULL && s->quad_head == NULL) {
      continue;
    }
    if (s->spec.tex_obj != 0) {
      dl->flags |= dl_has_tex;
    }

    for (l = s->tri_head; l; l = l->next) {
      add_face(M,
               l->data, l->data + 10, l->data + 20, NULL,
               l->data + 6, ti);
    }

    for (l = s->quad_head; l; l = l->next) {
      add_face(M,
               l->data, l->data + 10, l->data + 20, l->data + 30,
               l->data + 6, ti);
    }

    ++ti;
  }

  ti = 0;
  for (s = ctx->head; s; s = s->next) {
    if (s->tri_head == NULL && s->line_head == NULL && s->quad_head == NULL) {
      continue;
    }
    if (s->spec.tex_obj != 0) {
      dl->flags |= dl_has_tex;
    }

    for (l = s->line_head; l; l = l->next) {
      add_face(M, l->data, l->data + 10, NULL, NULL, l->data + 6, ti);
    }

    ++ti;
  }


  finish_faces_and_sort(M);
  add_creases(M);
  find_and_remove_t_junctions(M);
  finish_creases_and_join(M);
  smooth_vertices(M);
  merge_vertices(M);

  int total_vertices, total_indices;
  get_final_mesh_counts(M, &total_vertices, &total_indices);

  glGenBuffers(1, &dl->geo_vbo);
  glBindBuffer(GL_ARRAY_BUFFER, dl->geo_vbo);
  glGenBuffers(1, &dl->idx_vbo);
  glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, dl->idx_vbo);

  glBufferData(GL_ARRAY_BUFFER, total_vertices * sizeof(GLfloat) * VERT_STRIDE, NULL, GL_STATIC_DRAW);
  volatile GLfloat *vertex_ptr = (volatile GLfloat *)glMapBuffer(GL_ARRAY_BUFFER, GL_WRITE_ONLY);

  glBufferData(GL_ELEMENT_ARRAY_BUFFER, total_indices * sizeof(GLuint), NULL, GL_STATIC_DRAW);
  volatile GLuint *index_ptr = (volatile GLuint *)glMapBuffer(GL_ELEMENT_ARRAY_BUFFER, GL_WRITE_ONLY);

  // Grab variable size arrays for the start/offsets of each sub-part of our big pile-o-mesh...
  // the mesher will give us back our tris sorted by texture.

  int *line_start = (int *)LDrawBDPAllocate(ctx->alloc, sizeof(int) * total_texes);
  int *line_count = (int *)LDrawBDPAllocate(ctx->alloc, sizeof(int) * total_texes);
  int *tri_start  = (int *)LDrawBDPAllocate(ctx->alloc, sizeof(int) * total_texes);
  int *tri_count  = (int *)LDrawBDPAllocate(ctx->alloc, sizeof(int) * total_texes);
  int *quad_start = (int *)LDrawBDPAllocate(ctx->alloc, sizeof(int) * total_texes);
  int *quad_count = (int *)LDrawBDPAllocate(ctx->alloc, sizeof(int) * total_texes);

  write_indexed_mesh(
    M,
    total_vertices,
    vertex_ptr,
    total_indices,
    index_ptr,
    0,
    line_start,
    line_count,
    tri_start,
    tri_count,
    quad_start,
    quad_count);

  ti = 0;

  for (s = ctx->head; s; s = s->next) {
    if (s->tri_head == NULL && s->line_head == NULL && s->quad_head == NULL) {
      continue;
    }

    memcpy(&cur_tex->spec, &s->spec, sizeof(struct LDrawTextureSpec));

    cur_tex->quad_off   = quad_start[ti];
    cur_tex->line_off   = line_start[ti];
    cur_tex->tri_off    = tri_start[ti];
    cur_tex->quad_count = quad_count[ti];
    cur_tex->line_count = line_count[ti];
    cur_tex->tri_count  = tri_count[ti];

    ++ti;
    ++cur_tex;
  }

  destroy_mesh(M);

  #if WANT_STATS
  dl->vrt_count = total_vertices;
  dl->idx_count = total_indices;
  #endif

  glUnmapBuffer(GL_ARRAY_BUFFER);
  glUnmapBuffer(GL_ELEMENT_ARRAY_BUFFER);
  glBindBuffer(GL_ARRAY_BUFFER, 0);
  glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0);

  // Release the BDP that contains all of the build-related junk.
  LDrawBDPDestroy(ctx->alloc);

  #if TIME_SMOOTHING
  NSTimeInterval endTime = [NSDate timeIntervalSinceReferenceDate];
  #if WANT_STATS
  printf("Optimize took %f seconds for %d indices, %d vertices.\n",
         endTime - startTime,
         dl->idx_count,
         dl->vrt_count);
  #else
  printf("Optimize took %f seconds.\n", endTime - startTime);
  #endif
  #endif

  return(dl);
#else
  int total_texes    = 0;
  int total_vertices = 0;

  struct LDrawDLBuilderVertexLink *l;
  struct LDrawDLBuilderPerTex     *s;

  // Count up the total vertices we will need, for VBO space, as well
  // as the total distinct non-empty textures.
  for (s = ctx->head; s; s = s->next) {
    if (s->tri_head || s->line_head || s->quad_head) {
      ++total_texes;
    }
    for (l = s->tri_head; l; l = l->next) {
      total_vertices += l->vcount;
    }
    for (l = s->quad_head; l; l = l->next) {
      total_vertices += l->vcount;
    }
    for (l = s->line_head; l; l = l->next) {
      total_vertices += l->vcount;
    }
  }

  // No non-empty textures?  Bail out early - nuke our
  // context and get out.  Client code knows we get NO DL, rather than
  // an empty one.
  if (total_texes == 0) {
    LDrawBDPDestroy(ctx->alloc);
    return(NULL);
  }

  // Malloc DL structure with extra storage for variable-sized tex array.
  struct LDrawDL *dl = (struct LDrawDL *)malloc(sizeof(struct LDrawDL) + sizeof(
                                                  struct LDrawDLPerTex) * total_texes);

  // All per-session linked list ptrs start null.
  dl->next_dl        = NULL;
  dl->instance_head  = NULL;
  dl->instance_tail  = NULL;
  dl->instance_count = 0;

  dl->tex_count = total_texes;

  #if WANT_STATS
  dl->vrt_count = total_vertices;
  #endif

  // Generate and map a VBO for our mesh data.
  glGenBuffers(1, &dl->geo_vbo);
  glBindBuffer(GL_ARRAY_BUFFER, dl->geo_vbo);
  glBufferData(GL_ARRAY_BUFFER, total_vertices * sizeof(GLfloat) * VERT_STRIDE, NULL, GL_STATIC_DRAW);
  GLfloat *buf_ptr = (GLfloat *)glMapBuffer(GL_ARRAY_BUFFER, GL_WRITE_ONLY);
  int     cur_v    = 0;
  struct LDrawDLPerTex *cur_tex = dl->texes;
  dl->flags = ctx->flags;

  // Now: walk our building textures - for each non-empty one, we will copy it into
  // the tex array and push its vertices.
  for (s = ctx->head; s; s = s->next) {
    if (s->tri_head == NULL && s->line_head == NULL && s->quad_head == NULL) {
      continue;
    }
    if (s->spec.tex_obj != 0) {
      dl->flags |= dl_has_tex;
    }
    memcpy(&cur_tex->spec, &s->spec, sizeof(struct LDrawTextureSpec));
    cur_tex->line_off   = cur_v;
    cur_tex->line_count = 0;

    // These loops copy the actual geometry (in linked lists of data) into the
    // VBO that is mapped.

    for (l = s->line_head; l; l = l->next) {
      memcpy(buf_ptr, l->data, VERT_STRIDE * sizeof(GLfloat) * l->vcount);
      cur_tex->line_count += l->vcount;
      cur_v   += l->vcount;
      buf_ptr += (VERT_STRIDE * l->vcount);
    }

    cur_tex->tri_off   = cur_v;
    cur_tex->tri_count = 0;

    for (l = s->tri_head; l; l = l->next) {
      memcpy(buf_ptr, l->data, VERT_STRIDE * sizeof(GLfloat) * l->vcount);
      cur_tex->tri_count += l->vcount;
      cur_v   += l->vcount;
      buf_ptr += (VERT_STRIDE * l->vcount);
    }

    cur_tex->quad_off   = cur_v;
    cur_tex->quad_count = 0;

    for (l = s->quad_head; l; l = l->next) {
      memcpy(buf_ptr, l->data, VERT_STRIDE * sizeof(GLfloat) * l->vcount);
      cur_tex->quad_count += l->vcount;
      cur_v   += l->vcount;
      buf_ptr += (VERT_STRIDE * l->vcount);
    }

    ++cur_tex;
  }

  glUnmapBuffer(GL_ARRAY_BUFFER);
  glBindBuffer(GL_ARRAY_BUFFER, 0);

  // Release the BDP that contains all of the build-related junk.
  LDrawBDPDestroy(ctx->alloc);

  return(dl);
#endif
}// end LDrawDLBuilderFinish
/* *INDENT-ON* */


// ========== setup_tex_spec ======================================================
//
// Purpose:	Set up the GL with texturing info.
//
// Ntes:	DL implementation uses object-plane coordinate generation; when a
// sub-DL inherits a projection, that projection is transformed with the
// sub-DL to keep things in sync.
//
// The attr_texture_mix attribute controls whether the texture is visible
// or not - a temporary hack until we can get a clear texture.
//
// ================================================================================
static void setup_tex_spec(struct LDrawTextureSpec *spec)
{
  if (spec && spec->tex_obj) {
    glVertexAttrib1f(attr_texture_mix, 1.0f);
    glBindTexture(GL_TEXTURE_2D, spec->tex_obj);
    glTexGenfv(GL_S, GL_OBJECT_PLANE, spec->plane_s);
    glTexGenfv(GL_T, GL_OBJECT_PLANE, spec->plane_t);
  }
  else {
    glVertexAttrib1f(attr_texture_mix, 0.0f);
    // TODO: what texture IS bound when "untextured"?  We should
    // set up a 'white' texture 1x1 pixel so that (1) our texture state
    // is not illegal and (2) we waste NO bandwidth on texturing.
// glBindTexture(GL_TEXTURE_2D, 0);
  }
}// end setup_tex_spec


// ========== LDrawDLSessionCreate ================================================
//
// Purpose:	Create a new drawing session.  Drawing sessions sit entirely in a BDP
// for speed - most of our linked lists are just NULL.
//
// ================================================================================

/* *INDENT-OFF* */
struct LDrawDLSession *LDrawDLSessionCreate(const GLfloat model_view[16])
{
  struct LDrawBDP       *alloc   = LDrawBDPCreate();
  struct LDrawDLSession *session =
    (struct LDrawDLSession *)LDrawBDPAllocate(alloc, sizeof(struct LDrawDLSession));

  session->alloc       = alloc;
  session->dl_head     = NULL;
  session->dl_count    = 0;
  session->sorted_head = NULL;
  session->sort_count  = 0;
  #if WANT_STATS
  memset(&session->stats, 0, sizeof(session->stats));
  #endif
  memcpy(session->model_view, model_view, sizeof(GLfloat) * 16);
  session->inst_ring = inst_ring_last;
  // each session picks up a new buffer in the ring of instance buffers.
  inst_ring_last = (inst_ring_last + 1) % INST_RING_BUFFER_COUNT;
  return(session);
}// end LDrawDLSessionCreate
/* *INDENT-ON* */


// ========== compare_sorted_link =================================================
//
// Purpose:	Functor to compare two sorted instances by their "eval" value, which
// is eye space Z right now. API fits C qsort.
//
// ================================================================================
static int compare_sorted_link(const void *lhs, const void *rhs)
{
  const struct LDrawDLSortedInstanceLink *a = (const struct LDrawDLSortedInstanceLink *)lhs;
  const struct LDrawDLSortedInstanceLink *b = (const struct LDrawDLSortedInstanceLink *)rhs;

  return(a->eval - b->eval);
}// end compare_sorted_link


// ========== LDrawDLSessionDrawAndDestroy ========================================
//
// Purpose:	Draw any DLs that were deferred during drawing, then nuke the
// session object.
//
// ================================================================================
void LDrawDLSessionDrawAndDestroy(struct LDrawDLSession *session)
{
  struct LDrawDLInstance *inst;
  struct LDrawDL         *dl;

  // INSTANCED DRAWING CASE

  if (session->dl_head) {
    // Build a var-sized array of segments to record our instances for hardware instancing.  We may not need it for every DL but that's okay.
    struct LDrawDLSegment *segments =
      (struct LDrawDLSegment *)LDrawBDPAllocate(session->alloc,
                                                sizeof(struct LDrawDLSegment) * session->dl_count);
    struct LDrawDLSegment *cur_segment = segments;

    // If we do not yet have a VBO for instancing, build one now.
    if (inst_vbo_ring[session->inst_ring] == 0) {
      glGenBuffers(1, &inst_vbo_ring[session->inst_ring]);
    }


    // Map our instance buffer so we can write instancing data.
    glBindBuffer(GL_ARRAY_BUFFER, inst_vbo_ring[session->inst_ring]);
    glBufferData(GL_ARRAY_BUFFER, INST_MAX_COUNT * sizeof(GLfloat) * 24, NULL, GL_DYNAMIC_DRAW);
    GLfloat *inst_base  = (GLfloat *)glMapBuffer(GL_ARRAY_BUFFER, GL_WRITE_ONLY);
    GLfloat *inst_data  = inst_base;
    int     inst_remain = INST_MAX_COUNT;

    // Main loop 1: we will walk every instanced DL and either accumulate its instances (for hardware instancing) or just draw now
    // (For attribute instancing).
    while (session->dl_head)
    {
      dl = session->dl_head;

      if (dl->instance_count >= get_instance_cutoff() && inst_remain >= dl->instance_count) {
        // If we have capacity for hw instancing and this DL is used enough, create a segment record and fill it out.
        cur_segment->geo_vbo = dl->geo_vbo;
        #if WANT_SMOOTH
        cur_segment->idx_vbo = dl->idx_vbo;
        #endif
        cur_segment->dl         = &dl->texes[0];
        cur_segment->inst_base  = NULL;
        cur_segment->inst_base += (inst_data - inst_base);
        cur_segment->inst_count = dl->instance_count;

        #if WANT_STATS
        session->stats.num_btch_ins++;
        session->stats.num_inst_ins += (dl->instance_count);
        session->stats.num_vert_ins += (dl->instance_count * dl->vrt_count);
        session->stats.num_work_ins += dl->vrt_count;
        #endif

        // Now walk the instance list, copying the instances into the instance VBO one by one.

        for (inst = dl->instance_head; inst; inst = inst->next) {
          copy_vec4(inst_data, inst->color);
          copy_vec4(inst_data + 4, inst->comp);
          inst_data[8]  = inst->transform[0];   // Note: copy on transpose to get matrix into right form!
          inst_data[9]  = inst->transform[4];
          inst_data[10] = inst->transform[8];
          inst_data[11] = inst->transform[12];
          inst_data[12] = inst->transform[1];
          inst_data[13] = inst->transform[5];
          inst_data[14] = inst->transform[9];
          inst_data[15] = inst->transform[13];
          inst_data[16] = inst->transform[2];
          inst_data[17] = inst->transform[6];
          inst_data[18] = inst->transform[10];
          inst_data[19] = inst->transform[14];
          inst_data[20] = inst->transform[3];
          inst_data[21] = inst->transform[7];
          inst_data[22] = inst->transform[11];
          inst_data[23] = inst->transform[15];
          inst_data    += 24;
          --inst_remain;
        }
        ++cur_segment;
      }
      else {
        #if WANT_STATS
        session->stats.num_btch_att++;
        session->stats.num_inst_att += (dl->instance_count);
        session->stats.num_vert_att += (dl->instance_count * dl->vrt_count);
        session->stats.num_work_att += dl->vrt_count;
        #endif

        // Immediate mode instancing - we draw now!  So bind up the mesh of this DL.
        glBindBuffer(GL_ARRAY_BUFFER, dl->geo_vbo);
        #if WANT_SMOOTH
        glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, dl->idx_vbo);
        #endif
        float *p = NULL;
        glVertexAttribPointer(attr_position, 3, GL_FLOAT, GL_FALSE, VERT_STRIDE * sizeof(GLfloat), p);
        glVertexAttribPointer(attr_normal,
                              3,
                              GL_FLOAT,
                              GL_FALSE,
                              VERT_STRIDE * sizeof(GLfloat),
                              p + 3);
        glVertexAttribPointer(attr_color,
                              4,
                              GL_FLOAT,
                              GL_FALSE,
                              VERT_STRIDE * sizeof(GLfloat),
                              p + 6);

        // Now walk the instance list...push instance data into attributes in immediate mode and draw.
        for (inst = dl->instance_head; inst; inst = inst->next) {
          glVertexAttrib4f(attr_transform_x,
                           inst->transform[0],
                           inst->transform[4],
                           inst->transform[8],
                           inst->transform[12]);
          glVertexAttrib4f(attr_transform_x + 1,
                           inst->transform[1],
                           inst->transform[5],
                           inst->transform[9],
                           inst->transform[13]);
          glVertexAttrib4f(attr_transform_x + 2,
                           inst->transform[2],
                           inst->transform[6],
                           inst->transform[10],
                           inst->transform[14]);
          glVertexAttrib4f(attr_transform_x + 3,
                           inst->transform[3],
                           inst->transform[7],
                           inst->transform[11],
                           inst->transform[15]);

          glVertexAttrib4fv(attr_color_current, inst->color);
          glVertexAttrib4fv(attr_color_compliment, inst->comp);

          struct LDrawDLPerTex *tptr = dl->texes;

          #if WANT_SMOOTH
          if (tptr->line_count) {
            glDrawElements(GL_LINES, tptr->line_count, GL_UNSIGNED_INT, idx_null + tptr->line_off);
          }
          if (tptr->tri_count) {
            glDrawElements(GL_TRIANGLES, tptr->tri_count, GL_UNSIGNED_INT,
                           idx_null + tptr->tri_off);
          }
          if (tptr->quad_count) {
            glDrawElements(GL_QUADS, tptr->quad_count, GL_UNSIGNED_INT, idx_null + tptr->quad_off);
          }
          #else
          if (tptr->line_count) {
            glDrawArrays(GL_LINES, tptr->line_off, tptr->line_count);
          }
          if (tptr->tri_count) {
            glDrawArrays(GL_TRIANGLES, tptr->tri_off, tptr->tri_count);
          }
          if (tptr->quad_count) {
            glDrawArrays(GL_QUADS, tptr->quad_off, tptr->quad_count);
          }
          #endif
        }
      }

      dl->instance_head  = dl->instance_tail = NULL;
      dl->instance_count = 0;
      // Bug fix: bump the list head FIRST (pop front) before we blow things up, lest we use freed memory.
      session->dl_head = dl->next_dl;
      if (dl->flags & dl_needs_destroy) {
        LDrawDLDestroy(dl);
      }
      else {
        dl->next_dl = NULL;
      }
    }

    // Hardware instancing: unmap our hardware instance buffer and if we got data,
    // set up the GPU for hardware instancing.

    glBindBuffer(GL_ARRAY_BUFFER, inst_vbo_ring[session->inst_ring]);
    glUnmapBuffer(GL_ARRAY_BUFFER);


    if (segments != cur_segment) {
      glEnableVertexAttribArray(attr_transform_x);
      glEnableVertexAttribArray(attr_transform_y);
      glEnableVertexAttribArray(attr_transform_z);
      glEnableVertexAttribArray(attr_transform_w);
      glEnableVertexAttribArray(attr_color_current);
      glEnableVertexAttribArray(attr_color_compliment);
      glVertexAttribDivisorARB(attr_transform_x, 1);
      glVertexAttribDivisorARB(attr_transform_y, 1);
      glVertexAttribDivisorARB(attr_transform_z, 1);
      glVertexAttribDivisorARB(attr_transform_w, 1);
      glVertexAttribDivisorARB(attr_color_current, 1);
      glVertexAttribDivisorARB(attr_color_compliment, 1);

      // Main loop 2 over DLs - for each DL that had hw-instances we built a segment
      // in our array.  Bind the DL itself, as well as the instance pointers, and do an instanced-draw.

      struct LDrawDLSegment *s;
      for (s = segments; s < cur_segment; ++s) {
        glBindBuffer(GL_ARRAY_BUFFER, s->geo_vbo);
        #if WANT_SMOOTH
        glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, s->idx_vbo);
        #endif
        float *p = NULL;
        glVertexAttribPointer(attr_position, 3, GL_FLOAT, GL_FALSE, VERT_STRIDE * sizeof(GLfloat), p);
        glVertexAttribPointer(attr_normal,
                              3,
                              GL_FLOAT,
                              GL_FALSE,
                              VERT_STRIDE * sizeof(GLfloat),
                              p + 3);
        glVertexAttribPointer(attr_color,
                              4,
                              GL_FLOAT,
                              GL_FALSE,
                              VERT_STRIDE * sizeof(GLfloat),
                              p + 6);

        glBindBuffer(GL_ARRAY_BUFFER, inst_vbo_ring[session->inst_ring]);

        p = s->inst_base;
        glVertexAttribPointer(attr_color_current, 4, GL_FLOAT, GL_FALSE, 24 * sizeof(GLfloat), p);
        glVertexAttribPointer(attr_color_compliment,
                              4,
                              GL_FLOAT,
                              GL_FALSE,
                              24 * sizeof(GLfloat),
                              p + 4);
        glVertexAttribPointer(attr_transform_x, 4, GL_FLOAT, GL_FALSE, 24 * sizeof(GLfloat), p + 8);
        glVertexAttribPointer(attr_transform_y, 4, GL_FLOAT, GL_FALSE, 24 * sizeof(GLfloat), p + 12);
        glVertexAttribPointer(attr_transform_z, 4, GL_FLOAT, GL_FALSE, 24 * sizeof(GLfloat), p + 16);
        glVertexAttribPointer(attr_transform_w, 4, GL_FLOAT, GL_FALSE, 24 * sizeof(GLfloat), p + 20);

        #if WANT_SMOOTH
        if (s->dl->line_count) {
          glDrawElementsInstancedARB(GL_LINES,
                                     s->dl->line_count,
                                     GL_UNSIGNED_INT,
                                     idx_null + s->dl->line_off,
                                     s->inst_count);
        }
        if (s->dl->tri_count) {
          glDrawElementsInstancedARB(GL_TRIANGLES,
                                     s->dl->tri_count,
                                     GL_UNSIGNED_INT,
                                     idx_null + s->dl->tri_off,
                                     s->inst_count);
        }
        if (s->dl->quad_count) {
          glDrawElementsInstancedARB(GL_QUADS,
                                     s->dl->quad_count,
                                     GL_UNSIGNED_INT,
                                     idx_null + s->dl->quad_off,
                                     s->inst_count);
        }
        #else
        if (s->dl->line_count) {
          glDrawArraysInstancedARB(GL_LINES, s->dl->line_off, s->dl->line_count, s->inst_count);
        }
        if (s->dl->tri_count) {
          glDrawArraysInstancedARB(GL_TRIANGLES, s->dl->tri_off, s->dl->tri_count, s->inst_count);
        }
        if (s->dl->quad_count) {
          glDrawArraysInstancedARB(GL_QUADS, s->dl->quad_off, s->dl->quad_count, s->inst_count);
        }
        #endif
      }

      glDisableVertexAttribArray(attr_transform_x);
      glDisableVertexAttribArray(attr_transform_y);
      glDisableVertexAttribArray(attr_transform_z);
      glDisableVertexAttribArray(attr_transform_w);
      glDisableVertexAttribArray(attr_color_current);
      glDisableVertexAttribArray(attr_color_compliment);
      glVertexAttribDivisorARB(attr_transform_x, 0);
      glVertexAttribDivisorARB(attr_transform_y, 0);
      glVertexAttribDivisorARB(attr_transform_z, 0);
      glVertexAttribDivisorARB(attr_transform_w, 0);
      glVertexAttribDivisorARB(attr_color_current, 0);
      glVertexAttribDivisorARB(attr_color_compliment, 0);
    }
  }

  // MAIN LOOP 3: sorted deferred drawing (!)

  struct LDrawDLSortedInstanceLink *l;
  if (session->sorted_head) {
    // If we have any sorting to do, allocate an array of the size of all sorted geometry for sorting purposes.
    struct LDrawDLSortedInstanceLink *arr = (struct LDrawDLSortedInstanceLink *)LDrawBDPAllocate(
      session->alloc,
      sizeof(struct LDrawDLSortedInstanceLink) * session->sort_count);
    struct LDrawDLSortedInstanceLink *p = arr;

    // Copy each sorted instance into our array.  "Eval" is the measurement of distance - calculate eye-space Z and use that.
    for (l = session->sorted_head; l; l = l->next) {
      float v[4] =
      {
        l->transform[12],
        l->transform[13],
        l->transform[14], 1.0f
      };
      memcpy(p, l, sizeof(struct LDrawDLSortedInstanceLink));
      float v_eye[4];
      applyMatrix(v_eye, session->model_view, v);
      p->eval = v_eye[2];
      ++p;
    }

    // Now: sort our array ascending to get far to near in eye space.
    qsort(arr, session->sort_count, sizeof(struct LDrawDLSortedInstanceLink), compare_sorted_link);

    // NOW we can walk our sorted array and draw each brick, 1x1.  This code is a rehash of the "draw now"
    // code in LDrawDLDraw and could be factored.
    l = arr;
    int lc;
    for (lc = 0; lc < session->sort_count; ++lc) {
// int i;
// for(i = 0; i < 4; ++i)
// glVertexAttrib4f(attr_transform_x+i,l->transform[i],l->transform[4+i],l->transform[8+i],l->transform[12+i]);

      glVertexAttrib4f(attr_transform_x,
                       l->transform[0],
                       l->transform[4],
                       l->transform[8],
                       l->transform[12]);
      glVertexAttrib4f(attr_transform_x + 1, l->transform[1], l->transform[5], l->transform[9],
                       l->transform[13]);
      glVertexAttrib4f(attr_transform_x + 2, l->transform[2], l->transform[6], l->transform[10],
                       l->transform[14]);
      glVertexAttrib4f(attr_transform_x + 3, l->transform[3], l->transform[7], l->transform[11],
                       l->transform[15]);

      glVertexAttrib4fv(attr_color_current, l->color);
      glVertexAttrib4fv(attr_color_compliment, l->comp);

      dl = l->dl;
      glBindBuffer(GL_ARRAY_BUFFER, dl->geo_vbo);
      #if WANT_SMOOTH
      glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, dl->idx_vbo);
      #endif
      float *p = NULL;
      glVertexAttribPointer(attr_position, 3, GL_FLOAT, GL_FALSE, VERT_STRIDE * sizeof(GLfloat), p);
      glVertexAttribPointer(attr_normal, 3, GL_FLOAT, GL_FALSE, VERT_STRIDE * sizeof(GLfloat), p + 3);
      glVertexAttribPointer(attr_color, 4, GL_FLOAT, GL_FALSE, VERT_STRIDE * sizeof(GLfloat), p + 6);

      struct LDrawDLPerTex *tptr = dl->texes;

      int t;
      for (t = 0; t < dl->tex_count; ++t, ++tptr) {
        if (tptr->spec.tex_obj) {
          setup_tex_spec(&tptr->spec);
        }
        else {
          setup_tex_spec(&l->spec);
        }

        #if WANT_SMOOTH
        if (tptr->line_count) {
          glDrawElements(GL_LINES, tptr->line_count, GL_UNSIGNED_INT, idx_null + tptr->line_off);
        }
        if (tptr->tri_count) {
          glDrawElements(GL_TRIANGLES, tptr->tri_count, GL_UNSIGNED_INT, idx_null + tptr->tri_off);
        }
        if (tptr->quad_count) {
          glDrawElements(GL_QUADS, tptr->quad_count, GL_UNSIGNED_INT, idx_null + tptr->quad_off);
        }
        #else
        if (tptr->line_count) {
          glDrawArrays(GL_LINES, tptr->line_off, tptr->line_count);
        }
        if (tptr->tri_count) {
          glDrawArrays(GL_TRIANGLES, tptr->tri_off, tptr->tri_count);
        }
        if (tptr->quad_count) {
          glDrawArrays(GL_QUADS, tptr->quad_off, tptr->quad_count);
        }
        #endif
      }
      ++l;
    }
  }

  glBindBuffer(GL_ARRAY_BUFFER, 0);
  #if WANT_SMOOTH
  glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0);
  #endif

  #if WANT_STATS
  printf("Immediate drawing: %d batches, %d vertices.\n",
         session->stats.num_btch_imm,
         session->stats.num_vert_imm);
  printf("Sorted drawing: %d batches, %d vertices.\n",
         session->stats.num_btch_srt,
         session->stats.num_vert_srt);
  printf("Attribute instancing: %d batches, %d instances, %d (%d) vertices.\n",
         session->stats.num_btch_att,
         session->stats.num_inst_att,
         session->stats.num_work_att,
         session->stats.num_vert_att);
  printf("Hardware instancing: %d batches, %d instances, %d (%d) vertices.\n",
         session->stats.num_btch_ins,
         session->stats.num_inst_ins,
         session->stats.num_work_ins,
         session->stats.num_vert_ins);
  printf("Working set estimate (MB): %zd\n",
         (session->stats.num_vert_srt +
          session->stats.num_vert_imm +
          session->stats.num_work_ins +
          session->stats.num_work_att) * VERT_STRIDE * sizeof(GLfloat) / (1024 * 1024));
  #endif

  // Finally done - all allocations for session (including our own obj) come from a BDP, so cleanup is quick.
  // Instance VBO remains to be reused.
  // DLs themselves live on beyond session.
  LDrawBDPDestroy(session->alloc);
}// end LDrawDLSessionDrawAndDestroy


// ========== LDrawDLDraw =========================================================
//
// Purpose:	Draw a DL, or save it for later drawing.
//
// Notes:	This routine takes all of the current 'state' and draws or records
// an instance.
//
// Pass draw_now as true to FORCE immediate drawing and disable all of
// the instancing/sorting stuff.  This is needed if there is extra GL
// state like polygon offset that must be used now that isn't recorded
// by this API.
//
// ================================================================================
void LDrawDLDraw(
  struct LDrawDLSession *session,
  struct LDrawDL *dl,
  struct LDrawTextureSpec *spec,
  const GLfloat cur_color[4],
  const GLfloat cmp_color[4],
  const GLfloat transform[16],
  int draw_now)
{
  if (!draw_now) {
    // Sort case.  We want sort if:
    // 1. There is alpha baked into our meshes permanently or
    // 2. Our mesh uses meta colors and the current meta colors have alpha.

    int want_sort = (dl->flags & dl_has_alpha) ||
      ((dl->flags & dl_has_meta) && (cur_color[3] < 1.0f || cmp_color[3] < 1.0f));
    if (want_sort) {
      #if WANT_STATS
      session->stats.num_btch_srt++;
      session->stats.num_vert_srt += dl->vrt_count;
      #endif

      // Build a sorted link, copy the instance data to it, and link it up to our session for later processing.
      struct LDrawDLSortedInstanceLink *link =
        LDrawBDPAllocate(session->alloc, sizeof(struct LDrawDLSortedInstanceLink));
      link->next           = session->sorted_head;
      session->sorted_head = link;
      link->dl             = dl;
      memcpy(link->color, cur_color, sizeof(GLfloat) * 4);
      memcpy(link->comp, cmp_color, sizeof(GLfloat) * 4);
      memcpy(link->transform, transform, sizeof(GLfloat) * 16);
      session->sort_count++;
      if (spec) {
        memcpy(&link->spec, spec, sizeof(struct LDrawTextureSpec));
      }
      else {
        memset(&link->spec, 0, sizeof(struct LDrawTextureSpec));
      }
      return;
    }

    // We can instance if:
    // 1. No texture is being applied to us AND
    // 2. There isn't any texturing baked into the DL.
    if ((spec == NULL || spec->tex_obj == 0) && (dl->flags & dl_has_tex) == 0) {
      // assert(dl->next_dl == NULL || session->dl_head != NULL);

      // This is the first deferred instance for this DL - link this DL into our session so that we can find it later.
      if (dl->instance_head == NULL) {
        session->dl_count++;
        dl->next_dl      = session->dl_head;
        session->dl_head = dl;
      }
      // Copy our instance data into a LDrawDLInstance and link that into the DL for later use.
      struct LDrawDLInstance *inst =
        (struct LDrawDLInstance *)LDrawBDPAllocate(session->alloc, sizeof(struct LDrawDLInstance));
      {
        if (dl->instance_head == NULL) {
          dl->instance_head = inst;
          dl->instance_tail = inst;
        }
        else {
          dl->instance_tail->next = inst;
          dl->instance_tail       = inst;
        }
        inst->next = NULL;
        ++dl->instance_count;

        memcpy(inst->color, cur_color, sizeof(GLfloat) * 4);
        memcpy(inst->comp, cmp_color, sizeof(GLfloat) * 4);
        memcpy(inst->transform, transform, sizeof(GLfloat) * 16);
      }
      return;
    }
  }

  // IMMEDIATE MODE DRAW CASE!  If we get here, we are going to draw this DL right now at this
  // position.
  #if WANT_STATS
  session->stats.num_btch_imm++;
  session->stats.num_vert_imm += dl->vrt_count;
  #endif

  // Push current transform & color into attribute state.
  int i;
  for (i = 0; i < 4; ++i) {
    glVertexAttrib4f(attr_transform_x + i, transform[i], transform[4 + i], transform[8 + i],
                     transform[12 + i]);
  }
  glVertexAttrib4fv(attr_color_current, cur_color);
  glVertexAttrib4fv(attr_color_compliment, cmp_color);

  assert(dl->tex_count > 0);

  // Bind our DL VBO and set up ptrs.
  glBindBuffer(GL_ARRAY_BUFFER, dl->geo_vbo);
  #if WANT_SMOOTH
  glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, dl->idx_vbo);
  #endif
  float *p = NULL;
  glVertexAttribPointer(attr_position, 3, GL_FLOAT, GL_FALSE, VERT_STRIDE * sizeof(GLfloat), p);
  glVertexAttribPointer(attr_normal, 3, GL_FLOAT, GL_FALSE, VERT_STRIDE * sizeof(GLfloat), p + 3);
  glVertexAttribPointer(attr_color, 4, GL_FLOAT, GL_FALSE, VERT_STRIDE * sizeof(GLfloat), p + 6);

  struct LDrawDLPerTex *tptr = dl->texes;

  if (dl->tex_count == 1 && tptr->spec.tex_obj == 0 && (spec == NULL || spec->tex_obj == 0)) {
    // Special case: one untextured mesh - just draw.
    #if WANT_SMOOTH
    if (tptr->line_count) {
      glDrawElements(GL_LINES, tptr->line_count, GL_UNSIGNED_INT, idx_null + tptr->line_off);
    }
    if (tptr->tri_count) {
      glDrawElements(GL_TRIANGLES, tptr->tri_count, GL_UNSIGNED_INT, idx_null + tptr->tri_off);
    }
    if (tptr->quad_count) {
      glDrawElements(GL_QUADS, tptr->quad_count, GL_UNSIGNED_INT, idx_null + tptr->quad_off);
    }
    #else
    if (tptr->line_count) {
      glDrawArrays(GL_LINES, tptr->line_off, tptr->line_count);
    }
    if (tptr->tri_count) {
      glDrawArrays(GL_TRIANGLES, tptr->tri_off, tptr->tri_count);
    }
    if (tptr->quad_count) {
      glDrawArrays(GL_QUADS, tptr->quad_off, tptr->quad_count);
    }
    #endif
  }
  else {
    // Textured case - for each texture set up the DL texture (or current
    // texture if none), then draw.
    int t;
    for (t = 0; t < dl->tex_count; ++t, ++tptr) {
      if (tptr->spec.tex_obj) {
        setup_tex_spec(&tptr->spec);
      }
      else {
        setup_tex_spec(spec);
      }

      #if WANT_SMOOTH
      if (tptr->line_count) {
        glDrawElements(GL_LINES, tptr->line_count, GL_UNSIGNED_INT, idx_null + tptr->line_off);
      }
      if (tptr->tri_count) {
        glDrawElements(GL_TRIANGLES, tptr->tri_count, GL_UNSIGNED_INT, idx_null + tptr->tri_off);
      }
      if (tptr->quad_count) {
        glDrawElements(GL_QUADS, tptr->quad_count, GL_UNSIGNED_INT, idx_null + tptr->quad_off);
      }
      #else
      if (tptr->line_count) {
        glDrawArrays(GL_LINES, tptr->line_off, tptr->line_count);
      }
      if (tptr->tri_count) {
        glDrawArrays(GL_TRIANGLES, tptr->tri_off, tptr->tri_count);
      }
      if (tptr->quad_count) {
        glDrawArrays(GL_QUADS, tptr->quad_off, tptr->quad_count);
      }
      #endif
    }

    setup_tex_spec(spec);
  }
}// end LDrawDLDraw


// ========== LDrawDLDestroy ======================================================
//
// Purpose: free a display list - release GL and system memory.
//
// ================================================================================
void LDrawDLDestroy(struct LDrawDL *dl)
{
  if (dl->instance_head != NULL) {
    // Special case: if our DL is destroyed WHILE a session is using it for
    // deferred drawing, we do NOT destroy it - we mark it for destruction
    // later and the session nukes it.  This is needed for the case where
    // client code creates a DL, draws it, and immediately destroys it, as
    // a silly way to get 'immediate' drawing.  In this case, the session
    // may have intentionally deferred the DL.
    dl->flags |= dl_needs_destroy;
    return;
  }
  // Make sure that no instances from a session are queued to this list; if we
  // are in Q and run now, we'll cause seg faults later.  This assert hits
  // when: (1) we build a temp DL and don't mark it as temp or (2) we for some
  // reason inval a DL mid-draw, which is usually a sign of coding error.
  assert(dl->instance_head == NULL);

  #if WANT_SMOOTH
  glDeleteBuffers(1, &dl->idx_vbo);
  #endif
  glDeleteBuffers(1, &dl->geo_vbo);
  free(dl);
}// end LDrawDLDestroy
