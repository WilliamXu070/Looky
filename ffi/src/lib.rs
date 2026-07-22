use std::ffi::CStr;
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;

use step::ap214::{Entity, SiPrefix, SiUnitName};
use step::step_file::StepFile;
use triangulate::triangulate::triangulate;

#[derive(Copy, Clone)]
#[repr(C)]
pub struct FoxtrotFloat3 {
    pub x: f32,
    pub y: f32,
    pub z: f32,
}

impl From<nalgebra_glm::DVec3> for FoxtrotFloat3 {
    fn from(value: nalgebra_glm::DVec3) -> Self {
        Self {
            x: value.x as f32,
            y: value.y as f32,
            z: value.z as f32,
        }
    }
}

#[derive(Copy, Clone)]
#[repr(C)]
pub struct FoxtrotFaceRecord {
    pub brep_id: u64,
    pub instance_id: u64,
    pub entity_id: u64,
    pub triangle_start: usize,
    pub triangle_count: usize,
    pub surface_kind: u32,
    pub origin: FoxtrotFloat3,
    pub axis: FoxtrotFloat3,
    pub normal: FoxtrotFloat3,
    pub radius: f32,
    pub secondary_radius: f32,
    pub half_angle: f32,
}

#[derive(Copy, Clone)]
#[repr(C)]
pub struct FoxtrotEdgeRecord {
    pub brep_id: u64,
    pub instance_id: u64,
    pub entity_id: u64,
    pub curve_kind: u32,
    pub point_start: usize,
    pub point_count: usize,
    pub incident_face_start: usize,
    pub incident_face_count: usize,
}

struct MeshBuffers {
    vertices: Vec<f32>,
    normals: Vec<f32>,
    indices: Vec<u32>,
    faces: Vec<FoxtrotFaceRecord>,
    edges: Vec<FoxtrotEdgeRecord>,
    edge_points: Vec<FoxtrotFloat3>,
    edge_incident_face_ids: Vec<u64>,
    length_unit: u32,
}

fn load_step_mesh(path: &str) -> Result<MeshBuffers, Box<dyn std::error::Error>> {
    let data = std::fs::read(path)?;
    let flat = StepFile::strip_flatten(&data);
    let entities = StepFile::parse(&flat);
    let length_unit = detect_length_unit(&entities);
    let (mesh, _stats) = triangulate(&entities);

    let mut vertices = Vec::with_capacity(mesh.verts.len() * 3);
    let mut normals = Vec::with_capacity(mesh.verts.len() * 3);
    for vertex in &mesh.verts {
        vertices.extend([
            vertex.pos.x as f32,
            vertex.pos.y as f32,
            vertex.pos.z as f32,
        ]);
        normals.extend([
            vertex.norm.x as f32,
            vertex.norm.y as f32,
            vertex.norm.z as f32,
        ]);
    }

    let mut indices = Vec::with_capacity(mesh.triangles.len() * 3);
    for triangle in &mesh.triangles {
        indices.extend(triangle.verts.iter().copied());
    }

    let mut source_faces = mesh.source_faces;
    source_faces.sort_by_key(|face| (face.brep_id, face.instance_id, face.entity_id));
    let faces = source_faces
        .into_iter()
        .map(|face| FoxtrotFaceRecord {
            brep_id: face.brep_id,
            instance_id: face.instance_id,
            entity_id: face.entity_id,
            triangle_start: face.triangle_start,
            triangle_count: face.triangle_count,
            surface_kind: face.surface.kind as u32,
            origin: face.surface.origin.into(),
            axis: face.surface.axis.into(),
            normal: face.surface.normal.into(),
            radius: face.surface.radius as f32,
            secondary_radius: face.surface.secondary_radius as f32,
            half_angle: face.surface.half_angle as f32,
        })
        .collect();

    let mut source_edges = mesh.source_edges;
    source_edges.sort_by_key(|edge| (edge.brep_id, edge.instance_id, edge.entity_id));
    let mut edges = Vec::with_capacity(source_edges.len());
    let mut edge_points = Vec::new();
    let mut edge_incident_face_ids = Vec::new();
    for edge in source_edges {
        let point_start = edge_points.len();
        edge_points.extend(edge.points.into_iter().map(FoxtrotFloat3::from));
        let incident_face_start = edge_incident_face_ids.len();
        edge_incident_face_ids.extend(edge.incident_face_ids);
        edges.push(FoxtrotEdgeRecord {
            brep_id: edge.brep_id,
            instance_id: edge.instance_id,
            entity_id: edge.entity_id,
            curve_kind: edge.kind as u32,
            point_start,
            point_count: edge_points.len() - point_start,
            incident_face_start,
            incident_face_count: edge_incident_face_ids.len() - incident_face_start,
        });
    }

    Ok(MeshBuffers {
        vertices,
        normals,
        indices,
        faces,
        edges,
        edge_points,
        edge_incident_face_ids,
        length_unit,
    })
}

fn detect_length_unit(entities: &StepFile<'_>) -> u32 {
    for entity in &entities.0 {
        if let Entity::SiUnit(unit) = entity {
            if matches!(unit.name, SiUnitName::Metre) {
                return match unit.prefix {
                    Some(SiPrefix::Milli) => 1,
                    Some(SiPrefix::Centi) => 2,
                    None => 3,
                    _ => 0,
                };
            }
        }
        if let Entity::ConversionBasedUnit(unit) = entity {
            let name = unit.name.0.to_ascii_lowercase();
            if name.contains("inch") {
                return 4;
            }
            if name.contains("foot") || name.contains("feet") {
                return 5;
            }
        }
    }
    0
}

#[repr(C)]
pub struct MeshSlice {
    pub verts: *const f32,
    pub normals: *const f32,
    pub tris: *const u32,
    pub faces: *const FoxtrotFaceRecord,
    pub edges: *const FoxtrotEdgeRecord,
    pub edge_points: *const FoxtrotFloat3,
    pub edge_incident_face_ids: *const u64,
    pub vert_count: usize,
    pub tri_count: usize,
    pub face_count: usize,
    pub edge_count: usize,
    pub edge_point_count: usize,
    pub edge_incident_face_id_count: usize,
    pub length_unit: u32,
}

fn leak_boxed_slice<T>(values: Vec<T>) -> (*const T, usize) {
    let boxed = values.into_boxed_slice();
    let len = boxed.len();
    let pointer = Box::into_raw(boxed) as *mut T;
    (pointer as *const T, len)
}

unsafe fn free_boxed_slice<T>(pointer: *const T, len: usize) {
    if pointer.is_null() {
        return;
    }
    let slice = ptr::slice_from_raw_parts_mut(pointer as *mut T, len);
    drop(Box::from_raw(slice));
}

#[no_mangle]
pub extern "C" fn foxtrot_load_step(path: *const c_char, out_mesh: *mut MeshSlice) -> bool {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if path.is_null() || out_mesh.is_null() {
            return false;
        }
        let c_str = unsafe { CStr::from_ptr(path) };
        let Ok(path) = c_str.to_str() else {
            return false;
        };

        match load_step_mesh(path) {
            Ok(buffers) => {
                let (verts, vert_value_count) = leak_boxed_slice(buffers.vertices);
                let (normals, normal_value_count) = leak_boxed_slice(buffers.normals);
                let (tris, triangle_index_count) = leak_boxed_slice(buffers.indices);
                let (faces, face_count) = leak_boxed_slice(buffers.faces);
                let (edges, edge_count) = leak_boxed_slice(buffers.edges);
                let (edge_points, edge_point_count) = leak_boxed_slice(buffers.edge_points);
                let (edge_incident_face_ids, edge_incident_face_id_count) =
                    leak_boxed_slice(buffers.edge_incident_face_ids);

                debug_assert_eq!(vert_value_count, normal_value_count);
                unsafe {
                    *out_mesh = MeshSlice {
                        verts,
                        normals,
                        tris,
                        faces,
                        edges,
                        edge_points,
                        edge_incident_face_ids,
                        vert_count: vert_value_count / 3,
                        tri_count: triangle_index_count / 3,
                        face_count,
                        edge_count,
                        edge_point_count,
                        edge_incident_face_id_count,
                        length_unit: buffers.length_unit,
                    };
                }
                true
            }
            Err(_) => false,
        }
    }));

    result.unwrap_or(false)
}

#[no_mangle]
pub extern "C" fn foxtrot_free_mesh(slice: MeshSlice) {
    unsafe {
        free_boxed_slice(slice.verts, slice.vert_count * 3);
        free_boxed_slice(slice.normals, slice.vert_count * 3);
        free_boxed_slice(slice.tris, slice.tri_count * 3);
        free_boxed_slice(slice.faces, slice.face_count);
        free_boxed_slice(slice.edges, slice.edge_count);
        free_boxed_slice(slice.edge_points, slice.edge_point_count);
        free_boxed_slice(
            slice.edge_incident_face_ids,
            slice.edge_incident_face_id_count,
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cube_hole_preserves_step_faces_and_edges() {
        let path = format!(
            "{}/../testing/input/cube_hole.step",
            env!("CARGO_MANIFEST_DIR")
        );
        let buffers = load_step_mesh(&path).expect("cube_hole.step should load");

        assert_eq!(buffers.faces.len(), 7);
        assert!(buffers.faces.iter().any(|face| {
            face.entity_id == 129 && face.surface_kind == 2 && face.triangle_count > 0
        }));
        assert_eq!(buffers.edges.len(), 14);
        assert_eq!(buffers.length_unit, 3);
        assert!(buffers
            .edges
            .iter()
            .any(|edge| edge.entity_id == 63 && edge.curve_kind == 2));
        assert!(buffers
            .edges
            .iter()
            .any(|edge| edge.entity_id == 64 && edge.curve_kind == 2));

        let expected_indices = buffers.indices;
        let expected_faces: Vec<_> = buffers
            .faces
            .iter()
            .map(|face| {
                (
                    face.brep_id,
                    face.instance_id,
                    face.entity_id,
                    face.triangle_start,
                    face.triangle_count,
                )
            })
            .collect();
        let expected_edges: Vec<_> = buffers
            .edges
            .iter()
            .map(|edge| {
                (
                    edge.brep_id,
                    edge.instance_id,
                    edge.entity_id,
                    edge.curve_kind,
                    edge.point_count,
                )
            })
            .collect();
        for _ in 0..100 {
            let repeated =
                load_step_mesh(&path).expect("repeated cube_hole.step load should succeed");
            assert_eq!(repeated.indices, expected_indices);
            assert_eq!(
                repeated
                    .faces
                    .iter()
                    .map(|face| {
                        (
                            face.brep_id,
                            face.instance_id,
                            face.entity_id,
                            face.triangle_start,
                            face.triangle_count,
                        )
                    })
                    .collect::<Vec<_>>(),
                expected_faces
            );
            assert_eq!(
                repeated
                    .edges
                    .iter()
                    .map(|edge| {
                        (
                            edge.brep_id,
                            edge.instance_id,
                            edge.entity_id,
                            edge.curve_kind,
                            edge.point_count,
                        )
                    })
                    .collect::<Vec<_>>(),
                expected_edges
            );
        }
    }
}
