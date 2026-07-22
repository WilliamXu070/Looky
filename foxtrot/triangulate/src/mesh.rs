use std::convert::TryInto;

use nalgebra_glm::{DVec3, U32Vec3};

#[derive(Copy, Clone, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum SurfaceKind {
    Plane = 1,
    Cylinder = 2,
    Cone = 3,
    Sphere = 4,
    Torus = 5,
    BSpline = 6,
    Other = 7,
}

#[derive(Copy, Clone, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum CurveKind {
    Line = 1,
    Circle = 2,
    Ellipse = 3,
    BSpline = 4,
    Other = 5,
}

#[derive(Clone, Debug)]
pub struct SurfaceDescriptor {
    pub kind: SurfaceKind,
    pub origin: DVec3,
    pub axis: DVec3,
    pub normal: DVec3,
    pub radius: f64,
    pub secondary_radius: f64,
    pub half_angle: f64,
}

impl SurfaceDescriptor {
    pub fn new(kind: SurfaceKind) -> Self {
        Self {
            kind,
            origin: DVec3::zeros(),
            axis: DVec3::zeros(),
            normal: DVec3::zeros(),
            radius: 0.0,
            secondary_radius: 0.0,
            half_angle: 0.0,
        }
    }
}

#[derive(Clone, Debug)]
pub struct SourceFace {
    pub brep_id: u64,
    pub instance_id: u64,
    pub entity_id: u64,
    pub triangle_start: usize,
    pub triangle_count: usize,
    pub surface: SurfaceDescriptor,
}

#[derive(Clone, Debug)]
pub struct SourceEdge {
    pub brep_id: u64,
    pub instance_id: u64,
    pub entity_id: u64,
    pub kind: CurveKind,
    pub points: Vec<DVec3>,
    pub incident_face_ids: Vec<u64>,
}

#[derive(Copy, Clone, Debug)]
pub struct Vertex {
    pub pos: DVec3,
    pub norm: DVec3,
    pub color: DVec3,
}
#[derive(Copy, Clone, Debug)]
pub struct Triangle {
    pub verts: U32Vec3,
}

#[derive(Default)]
pub struct Mesh {
    pub verts: Vec<Vertex>,
    pub triangles: Vec<Triangle>,
    pub source_faces: Vec<SourceFace>,
    pub source_edges: Vec<SourceEdge>,
}

impl Mesh {
    // Combine two triangulations with an associative binary operator
    // (why yes, this _is_ a monoid)
    pub fn combine(mut a: Self, b: Self) -> Self {
        let dv = a.verts.len().try_into().expect("too many triangles");
        let dt = a.triangles.len();
        a.verts.extend(b.verts);
        a.triangles.extend(b.triangles.into_iter()
            .map(|t| Triangle { verts: t.verts.add_scalar(dv) }));
        a.source_faces.extend(b.source_faces.into_iter().map(|mut face| {
            face.triangle_start += dt;
            face
        }));
        a.source_edges.extend(b.source_edges);
        a
    }

    pub fn record_source_edge(
        &mut self,
        entity_id: u64,
        face_id: u64,
        kind: CurveKind,
        points: Vec<DVec3>,
    ) {
        if let Some(existing) = self.source_edges.iter_mut().find(|edge| {
            edge.brep_id == 0
                && edge.instance_id == 0
                && edge.entity_id == entity_id
        }) {
            if !existing.incident_face_ids.contains(&face_id) {
                existing.incident_face_ids.push(face_id);
                existing.incident_face_ids.sort_unstable();
            }
            return;
        }

        self.source_edges.push(SourceEdge {
            brep_id: 0,
            instance_id: 0,
            entity_id,
            kind,
            points,
            incident_face_ids: vec![face_id],
        });
    }

    /// Writes the triangulation to a STL, for debugging
    pub fn save_stl(&self, filename: &str) -> std::io::Result<()> {
        let mut out: Vec<u8> = Vec::new();
        for _ in 0..80 { // header
            out.push('x' as u8);
        }
        let u: u32 = self.triangles.len().try_into()
            .expect("Too many triangles");
        out.extend(&u.to_le_bytes());
        for t in self.triangles.iter() {
            out.extend(std::iter::repeat(0).take(12)); // normal
            for v in t.verts.iter() {
                let v = self.verts[*v as usize];
                out.extend(&(v.pos.x as f32).to_le_bytes());
                out.extend(&(v.pos.y as f32).to_le_bytes());
                out.extend(&(v.pos.z as f32).to_le_bytes());
            }
            out.extend(std::iter::repeat(0).take(2)); // attributes
        }
        std::fs::write(filename, out)
    }
}
