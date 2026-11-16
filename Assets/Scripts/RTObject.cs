using System.Collections.Generic;
using UnityEngine;
[System.Serializable]

public struct Triangle
{
    public int material_id;
    public Vector3 V0;
    public Vector3 E1;
    public Vector3 E2;
    // World-space unit vertex normals of V0, V0+E1, V0+E2, interpolated with (1-u-v, u, v) for smooth shading
    public Vector3 N0;
    public Vector3 N1;
    public Vector3 N2;
}

public struct SourceMesh
{
    public MeshFilter meshFilter;
    public Vector3[] vertices;
    public Vector3[] normals;   // world-space vertex normals: orient triangles and give the shading normals
    public int[] triangles;
}

public struct TraceMesh
{
    // TODO: Triangle could be 3 indices to arrays of V0[] + E[]
    public Triangle[] triangles;
    public int tri_count;
    public Bounds aabbox;
}


[System.Serializable]
public struct Mat
{
    public Vector3 diffuseColor;
    public Vector3 emissionColor;
    public byte smoothness;
}

public class RTObject : MonoBehaviour
{
    public SourceMesh source;
    // Shared material table, populated by MaterialBox
    public static List<Mat> materials = new List<Mat>();

    public int materialIndex;
    public Mat Material => materials[materialIndex];

    public TraceMesh mesh;

    public Transform obj_transform;

    public int objectID;

    public string objectName;

    public Bounds bounding_box;

    // Awake runs before any Start, so geometry is ready when other scripts query it in their Start
    void Awake()
    {
        source.meshFilter = GetComponent<MeshFilter>();
        obj_transform = GetComponent<Transform>();

        // Load the vertices of the mesh 
        source.vertices = source.meshFilter.mesh.vertices;
        source.triangles = source.meshFilter.mesh.triangles;

        obj_transform.TransformPoints(source.meshFilter.mesh.vertices, source.vertices);

        // Normals go to world space with the inverse-transpose (handles non-uniform and negative scale)
        source.normals = source.meshFilter.mesh.normals;
        Matrix4x4 normalMatrix = obj_transform.localToWorldMatrix.inverse.transpose;
        for (int i = 0; i < source.normals.Length; i++)
            source.normals[i] = normalMatrix.MultiplyVector(source.normals[i]);

        mesh = Convert_mesh(source);
        bounding_box = GeometryUtility.CalculateBounds(source.vertices, Matrix4x4.identity);
    }

    void Start()
    {
        // obj_transform.TransformPoints(source.meshFilter.mesh.vertices, source.vertices);
        // mesh = Convert_mesh(source);
        // bounding_box = GeometryUtility.CalculateBounds(source.vertices, Matrix4x4.identity);
    }

    // Debug: draw the baked face normal Cross(E1, E2) of every normalStride-th triangle in the Scene view
    public bool drawNormals = true;
    public int normalStride = 1;
    public float normalLength = 0.2f;

    // Update is called once per frame
    void Update()
    {
        // obj_transform.TransformPoints(source.meshFilter.mesh.vertices, source.vertices);
        // mesh = Convert_mesh(source);

        if (drawNormals)
            DrawDebugNormals();
    }

    void DrawDebugNormals()
    {
        if (mesh.triangles == null) return;
        int stride = Mathf.Max(1, normalStride);
        for (int i = 0; i < mesh.tri_count; i += stride)
        {
            Triangle t = mesh.triangles[i];
            Vector3 centroid = t.V0 + (t.E1 + t.E2) / 3f;
            Vector3 n = Vector3.Cross(t.E1, t.E2).normalized;
            // Color by direction so flipped faces stand out against their neighbours
            Color c = new Color(0.5f + 0.5f * n.x, 0.5f + 0.5f * n.y, 0.5f + 0.5f * n.z);
            Debug.DrawRay(centroid, n * normalLength, c);
        }
    }

    private TraceMesh Convert_mesh(SourceMesh original)
    {
        int triangle_count = original.triangles.Length / 3;

        TraceMesh newTraceMesh;
        newTraceMesh.tri_count = triangle_count;
        newTraceMesh.triangles = new Triangle[triangle_count];

        bool hasNormals = original.normals != null && original.normals.Length == original.vertices.Length;
        // Without normals, only a mirrored transform can flip Unity's outward (clockwise) winding
        bool mirrored = obj_transform.localToWorldMatrix.determinant < 0;

        for(int tri_idx = 0; tri_idx < triangle_count ;tri_idx += 1)
        {
            int i0 = original.triangles[3*tri_idx];
            int i1 = original.triangles[3*tri_idx+1];
            int i2 = original.triangles[3*tri_idx+2];

            Vector3 V0 = original.vertices[i0];
            Vector3 E1 = original.vertices[i1] - V0;
            Vector3 E2 = original.vertices[i2] - V0;

            // Orient so that Cross(E1, E2) points out of the surface; swapping the edges negates it
            bool flip = hasNormals
                ? Vector3.Dot(Vector3.Cross(E1, E2), original.normals[i0] + original.normals[i1] + original.normals[i2]) < 0
                : mirrored;
            Vector3 N0, N1, N2;
            if (hasNormals)
            {
                N0 = original.normals[i0].normalized;
                N1 = original.normals[i1].normalized;
                N2 = original.normals[i2].normalized;
            }
            else
            {
                // No vertex normals: flat shading with the face normal
                N0 = N1 = N2 = Vector3.Cross(E1, E2).normalized * (flip ? -1f : 1f);
            }

            if (flip)
            {
                // Swapping the edges swaps the barycentric u/v, so swap the matching normals too
                Vector3 tmp = E1; E1 = E2; E2 = tmp;
                tmp = N1; N1 = N2; N2 = tmp;
            }

            newTraceMesh.triangles[tri_idx].material_id = materialIndex;
            newTraceMesh.triangles[tri_idx].V0 = V0;
            newTraceMesh.triangles[tri_idx].E1 = E1;
            newTraceMesh.triangles[tri_idx].E2 = E2;
            newTraceMesh.triangles[tri_idx].N0 = N0;
            newTraceMesh.triangles[tri_idx].N1 = N1;
            newTraceMesh.triangles[tri_idx].N2 = N2;
        }

        newTraceMesh.aabbox = bounding_box;
    
        return newTraceMesh;
    }
}
