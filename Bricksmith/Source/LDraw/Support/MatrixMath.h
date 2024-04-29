// ==============================================================================
//
// File:		MatrixMath.h
//
// Purpose:		Mathematical library for computer graphics
//
// Stolen heavily from GraphicsGems.h
// Version 1.0 - Andrew Glassner
// from "Graphics Gems", Academic Press, 1990
//
// ==============================================================================
#ifndef _MatrixMath_
#define _MatrixMath_

#include OPEN_GL_HEADER
#include <stdbool.h>

#pragma mark Data Types
#pragma mark -

////////////////////////////////////////////////////////////////////////////////
//
// 2D geometry types
//
////////////////////////////////////////////////////////////////////////////////
typedef struct Point2Struct {
    double x, y;
} Point2, Vector2;


typedef struct Size2Struct {
    double width;
    double height;
} Size2;


typedef struct Box2Struct {
    Point2 origin;
    Size2  size;
} Box2;


////////////////////////////////////////////////////////////////////////////////
//
// 3D geometry types
//
////////////////////////////////////////////////////////////////////////////////

// 3D point
typedef struct Point3Struct {
    double x, y, z;
} Point3, Vector3, Tuple3;


// 3D integer point
typedef struct IntPoint3Struct {
    int x, y, z;
} IntPoint3;


// 3D Box
typedef struct Box3Struct {
    Point3 min, max;
} Box3;


// 3x3 Matrix
typedef struct Matrix3Struct {
    double element[3][3]; // [row][column]
} Matrix3;


typedef struct Ray3Struct {
    Point3  origin;
    Vector3 direction;
} Ray3;

typedef struct Segment3Struct {
    Point3 point0;
    Point3 point1;
} Segment3;


////////////////////////////////////////////////////////////////////////////////
//
// 4D geometry types
//
////////////////////////////////////////////////////////////////////////////////

// 4-by-4 matrix
typedef struct Matrix4Struct {
    double element[4][4]; // [row][column]
} Matrix4;


// 4-component vector
typedef struct {
    double x, y, z, w;
} Point4, Vector4, Tuple4;
// , Plane4;


// Transformation components; the data encoded in a transformation matrix.
typedef struct {
    Tuple3  scale;
    double  shear_XY;
    double  shear_XZ;
    double  shear_YZ;
    Tuple3  rotate; // in radians
    Vector3 translate;
    Tuple4  perspective;
} TransformComponents;


#pragma mark -
#pragma mark Constants
#pragma mark -
////////////////////////////////////////////////////////////////////////////////
//
// Constants
//
////////////////////////////////////////////////////////////////////////////////

#define PI              M_PI
#define SMALL_NUMBER    1.0e-6 // "close enough" zero for floating-point. 1e-8 is too small.

extern const Size2 ZeroSize2;
extern const Box2 ZeroBox2;
extern const Box3 InvalidBox;
extern const TransformComponents IdentityComponents;
extern const Matrix3 IdentityMatrix3;
extern const Matrix4 IdentityMatrix4;
extern const Point2  ZeroPoint2;
extern const Point3  ZeroPoint3;
extern const Point4  ZeroPoint4;

#pragma mark -
#pragma mark Macros
#pragma mark -
////////////////////////////////////////////////////////////////////////////////
//
// Macros
//
////////////////////////////////////////////////////////////////////////////////

// Radians to Degrees
#define degrees(radians)    ((radians) * 180 / PI)

// Degrees to Radians
#define radians(degrees)    ((degrees) * PI / 180)


/* find minimum of a and b */
// Defined for us by Objective-C
#if !defined(MIN)
#define MIN(a, b)    (((a) < (b)) ? (a) : (b))
#endif

/* find maximum of a and b */
#if !defined(MAX)
#define MAX(a, b)    (((a) > (b)) ? (a) : (b))
#endif

/* swap a and b (see Gem by Wyvill) */
#define SWAP(a, b)    { a ^= b; b ^= a; a ^= b; }

// Linear Interpolation
// from a (when t=0) to b (when t=1)
// (equivalent to a*(1 - t) + b*t
#define LERP(t, a, b)         \
        (                           \
            (a) + (((b) - (a)) * (t)) \
        )

/* clamp the input v to the specified range [l-h] */
#define CLAMP(v, l, h) \
        (                    \
            (v) < (l) ?        \
            (l)                \
  : (v) > (h) ?        \
            (h)                \
  : v                  \
        )


////////////////////////////////////////////////////////////////////////////////
//
// memory allocation macros
//
////////////////////////////////////////////////////////////////////////////////

/* create a new instance of a structure (see Gem by Hultquist) */
#define NEWSTRUCT(x)    (struct x *)(malloc((unsigned)sizeof(struct x)))

/* create a new instance of a type */
#define NEWTYPE(x)      (x *)(malloc((unsigned)sizeof(x)))


#pragma mark -
#pragma mark Prototypes
#pragma mark -
////////////////////////////////////////////////////////////////////////////////
//
// Function Prototypes
//
////////////////////////////////////////////////////////////////////////////////

extern size_t FloorPowerOfTwo(size_t value);
extern bool   FloatsApproximatelyEqual(double float1, double float2);

// 2-D
extern Point2 V2Make(double x, double y);

extern Vector2 V2Add(Vector2 a, Vector2 b);
extern Vector2 V2Sub(Vector2 a, Vector2 b);
extern Vector2 V2MulScalar(Vector2 a, float scalar);
extern Box2   V2MakeBox(double x, double y, double width, double height);
extern Box2   V2MakeBoxFromPoints(Point2 origin, Point2 maximum);
extern Size2  V2MakeSize(double width, double height);
extern bool   V2EqualBoxes(Box2 box1, Box2 box2);
extern bool   V2EqualSizes(Size2 size1, Size2 size2);
extern double V2BoxHeight(Box2 box);
extern double V2BoxWidth(Box2 box);
extern double V2BoxMaxX(Box2 box);
extern double V2BoxMaxY(Box2 box);
extern double V2BoxMidX(Box2 box);
extern double V2BoxMidY(Box2 box);
extern double V2BoxMinX(Box2 box);
extern double V2BoxMinY(Box2 box);
extern Box2   V2BoxInset(Box2 box, double dX, double dY);
extern bool   V2BoxContains(Box2 box, Point2 pin);
extern bool   V2PolygonContains(const Point2 *poly, int num_pts, Point2 pin);
extern bool   V2BoxIntersectsPolygon(Box2 bounds, const Point2 *poly, int num_pts);

extern double Matrix2x2Determinant(double, double, double, double);

// 3-D
extern Vector3  V3Make(double x, double y, double z);
extern Vector3 *V3Duplicate(Vector3 *a);
extern Vector3  V3FromV4(Vector4 originalVector);
extern Vector3  V3FromV4Normalize(Vector4 originalVector);
extern bool   V3EqualPoints(Point3 point1, Point3 point2);
extern bool   V3PointsWithinTolerance(Point3 point1, Point3 point2);
extern double V3SquaredLength(Vector3 v);
extern double V3Length(Vector3 v);
extern Vector3  V3Negate(Vector3 v);
extern Tuple3   V3AntiEuler(Tuple3 v); // Return Euler that is opposite v
extern Vector3  V3Normalize(Vector3 v);
extern Vector3  V3Scale(Vector3 v, double);
extern Vector3  V3Add(Vector3 a, Vector3 b);
extern Vector3  V3Sub(Vector3 a, Vector3 b);
extern double V3Dot(Vector3 a, Vector3 b);
extern Vector3  V3Lerp(Vector3 lo, Vector3 hi, double alpha);
extern Vector3  V3Combine(Vector3 a, Vector3 b, double ascl, double bscl);
extern Vector3  V3Mul(Vector3 a, Vector3 b);
extern Vector3  V3MulScalar(Vector3 a, double scalar);
extern double V3DistanceBetween2Points(Point3 a, Point3 b);
extern double V3DistanceFromPointToPlane(Point3 point, Vector3 planeNormal, Point3 pointOnPlane);
extern Vector3  V3Cross(Vector3 a, Vector3 b);
extern Point3 V3Midpoint(Point3 point1, Point3 point2);
extern Vector3  V3IsolateGreatestComponent(Vector3 vector);
extern void   V3Print(Point3 point);
extern bool   V3RayIntersectsTriangle(Ray3 ray,
    Point3                                 vert0,
    Point3                                 vert1,
    Point3                                 vert2,
    double                                 *distanceOut,
    Point2                                 *intersectPointOut);
extern bool   V3RayIntersectsSegment(Ray3 segment1, Segment3 segment2, double tolerance, double *distanceOut);
extern bool   V3RayIntersectsSphere(Ray3 ray, Point3 sphereCenter, double radius, double *distanceOut);

extern Box3   V3BoundsFromPoints(Point3 point1, Point3 point2);
extern Point3 V3CenterOfBox(Box3 box);
extern int    V3EqualBoxes(Box3 box1, Box3 box2);
extern Box3   V3UnionBox(Box3 aBox, Box3 bBox);
extern Box3   V3UnionBoxAndPoint(Box3 box, Point3 point);

extern Point3 V3MulPointByMatrix(Point3 pin, Matrix3 m);
extern Vector3  V3MulPointByProjMatrix(Point3 pin, Matrix4 m);
extern Matrix4  V3LookAt(Point3 eye, Point3 center, Vector3 up, Matrix4 modelview);
extern Point3 V3Project(Point3 objPoint, Matrix4 modelview, Matrix4 projection, Box2 viewport);
extern Point3 V3Unproject(Point3 viewportPoint, Matrix4 modelview, Matrix4 projection, Box2 viewport);

extern double Matrix3x3Determinant(double, double, double, double, double, double, double, double, double);
extern Matrix3  Matrix3MakeNormalTransformFromProjMatrix(Matrix4 transformationMatrix);

// 4-D
extern Vector4  V4Make(double x, double y, double z, double w);
extern Point4 V4FromPoint3(Vector3 originalPoint);
extern Vector4  V4MulPointByMatrix(Vector4 pin, Matrix4 m);
extern Matrix4  Matrix4CreateFromGLMatrix4(const GLfloat *glMatrix);
extern Matrix4  Matrix4CreateTransformation(TransformComponents *);
extern int    Matrix4DecomposeTransformation(Matrix4 originalMatrix, TransformComponents *decomposed);
extern Tuple3 Matrix4DecomposeXYZRotation(Matrix4 matrix);
extern Tuple3 Matrix4DecomposeZYXRotation(Matrix4 matrix);
extern Matrix4  Matrix4Multiply(Matrix4 a, Matrix4 b);
extern void   Matrix4MultiplyGLMatrices(GLfloat *a, GLfloat *b, GLfloat *result);
extern void   Matrix4GetGLMatrix4(Matrix4 matrix, GLfloat *glTransformation);
extern Matrix4  Matrix4Rotate(Matrix4 original, Tuple3 degreesToRotate);
extern Matrix4  Matrix4RotateModelview(Matrix4 original, Tuple3 degreesToRotate);
extern Matrix4  Matrix4Scale(Matrix4 original, Tuple3 scaleFactors);
extern Matrix4  Matrix4Translate(Matrix4 original, Vector3 displacement);
extern Matrix4  Matrix4Transpose(Matrix4 a);
extern Matrix4  Matrix4Invert(Matrix4 in);
extern void   Matrix4Adjoint(Matrix4 *, Matrix4 *);
extern double Matrix4x4Determinant(Matrix4 *);
extern void   Matrix4Print(Matrix4 *matrix);

extern bool   DepthOnTriangle(Point3 vert0, Point3 vert1, Point3 vert2, Point3 *test_pt);
extern bool   DepthOnLineSegment(Point3 vert0, Point3 vert1, double tolerance, Point3 *test_pt);

extern bool   VolumeCanIntersectBox(Box3 boundingVolume, Matrix4 transform, Box2 testBox);

extern bool   VolumeCanIntersectPoint(Box3 boundingVolume, Matrix4 transform, Box2 testPoint, // We provide a RANGE that our point is inside - this is how we get 'fuzzy' hits for infinitely thin geometry like lines.
    double testDepthSoFar);


#endif // _MatrixMath_
