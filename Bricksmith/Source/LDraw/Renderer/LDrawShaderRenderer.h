//
// LDrawShaderRenderer.h
// Bricksmith
//
// Created by bsupnik on 11/5/12.
// Copyright 2012 __MyCompanyName__. All rights reserved.
//

#import <Cocoa/Cocoa.h>

#import "LDrawRenderer.h"

/*
 *
 * LDrawShaderRenderer - an implementation of the LDrawRenderer API using GL shaders.
 *
 * The renderer maintains a stack view of OpenGL state; as directives push their
 * info to the renderer, containing LDraw parts push and pop state to affect the
 * child parts that are drawn via the depth-first traversal.
 *
 *
 */

enum
{
    attr_position = 0, // This defines the attribute indices for our particular shader.
    attr_normal,     // This must be kept in sync with the string list in the .m file.
    attr_color,
    attr_transform_x,
    attr_transform_y,
    attr_transform_z,
    attr_transform_w,
    attr_color_current,
    attr_color_compliment,
    attr_texture_mix,
    attr_count
};


// Stack depths for renderer.
#define COLOR_STACK_DEPTH        64
#define TEXTURE_STACK_DEPTH      128
#define TRANSFORM_STACK_DEPTH    64
#define DL_STACK_DEPTH           64

#define CULL_BOX_X               1024
#define CULL_BOX_Y               1024

struct  LDrawDLBuilder;
struct  LDrawBDP;
struct  LDrawDragHandleInstance;

@interface LDrawShaderRenderer : NSObject <LDrawRenderer, LDrawCollector>
{
    // DL session - this accumulates draw calls and sorts them.
    struct LDrawDLSession *session;
    struct LDrawBDP       *pool;
    // Color stack.
    GLfloat color_now[4];
    GLfloat compl_now[4];
    GLfloat color_stack[COLOR_STACK_DEPTH * 4];
    int     color_stack_top;
    // wire frame stack is just a count.
    int wire_frame_count;
    // Texture stack from push/pop texture.
    struct LDrawTextureSpec tex_stack[TEXTURE_STACK_DEPTH];
    int texture_stack_top;
    struct LDrawTextureSpec tex_now;
    // Transform stack from push/pop matrix.
    GLfloat transform_stack[TRANSFORM_STACK_DEPTH * 16];
    int     transform_stack_top;
    GLfloat transform_now[16];
    GLfloat cull_now[16];
    // DL stack from begin/end DL builds.
    struct LDrawDLBuilder *dl_stack[DL_STACK_DEPTH];
    int dl_stack_top;
    // This is the DL being built "right now".
    struct LDrawDLBuilder *dl_now;
    // Cached MVP from when shader is built.
    GLfloat mvp[16];
    // List of drag handles - deferred to draw at the end for perf and correct scaling.
    struct LDrawDragHandleInstance *drag_handles;
    // Needed to code Allen's res-independent drag handles...someday get this from viewport?
    GLfloat scale;
}

- (id)initWithScale:(double)scale modelView:(GLfloat *)mv_matrix projection:(GLfloat *)proj_matrix;

- (void)drawDragHandleImm:(GLfloat *)xyz withSize:(GLfloat)size;

@end
