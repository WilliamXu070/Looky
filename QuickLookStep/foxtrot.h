#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

typedef struct FoxtrotFloat3 {
  float x;
  float y;
  float z;
} FoxtrotFloat3;

typedef struct FoxtrotFaceRecord {
  uint64_t brep_id;
  uint64_t instance_id;
  uint64_t entity_id;
  uintptr_t triangle_start;
  uintptr_t triangle_count;
  uint32_t surface_kind;
  struct FoxtrotFloat3 origin;
  struct FoxtrotFloat3 axis;
  struct FoxtrotFloat3 normal;
  float radius;
  float secondary_radius;
  float half_angle;
} FoxtrotFaceRecord;

typedef struct FoxtrotEdgeRecord {
  uint64_t brep_id;
  uint64_t instance_id;
  uint64_t entity_id;
  uint32_t curve_kind;
  uintptr_t point_start;
  uintptr_t point_count;
  uintptr_t incident_face_start;
  uintptr_t incident_face_count;
} FoxtrotEdgeRecord;

typedef struct MeshSlice {
  const float *verts;
  const float *normals;
  const uint32_t *tris;
  const struct FoxtrotFaceRecord *faces;
  const struct FoxtrotEdgeRecord *edges;
  const struct FoxtrotFloat3 *edge_points;
  const uint64_t *edge_incident_face_ids;
  uintptr_t vert_count;
  uintptr_t tri_count;
  uintptr_t face_count;
  uintptr_t edge_count;
  uintptr_t edge_point_count;
  uintptr_t edge_incident_face_id_count;
  uint32_t length_unit;
} MeshSlice;

bool foxtrot_load_step(const char *path, struct MeshSlice *out_mesh);

void foxtrot_free_mesh(struct MeshSlice slice);
