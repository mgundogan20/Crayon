using System.Collections.Generic;
using UnityEngine;
[System.Serializable]

public struct Triangle
{
    public int material_id;
    public Vector3 V0;
    public Vector3 E1;
    public Vector3 E2;
}

public struct SourceMesh
{
    public MeshFilter meshFilter;
    public Vector3[] vertices;
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
        mesh = Convert_mesh(source);
        bounding_box = GeometryUtility.CalculateBounds(source.vertices, Matrix4x4.identity);
    }

    void Start()
    {
        // obj_transform.TransformPoints(source.meshFilter.mesh.vertices, source.vertices);
        // mesh = Convert_mesh(source);
        // bounding_box = GeometryUtility.CalculateBounds(source.vertices, Matrix4x4.identity);
    }

    // Update is called once per frame
    void Update()
    {
        // obj_transform.TransformPoints(source.meshFilter.mesh.vertices, source.vertices);
        // mesh = Convert_mesh(source);
    }

    private TraceMesh Convert_mesh(SourceMesh original)
    {
        int triangle_count = original.triangles.Length / 3;

        TraceMesh newTraceMesh;
        newTraceMesh.tri_count = triangle_count;
        newTraceMesh.triangles = new Triangle[triangle_count];

        for(int tri_idx = 0; tri_idx < triangle_count ;tri_idx += 1)
        {
            newTraceMesh.triangles[tri_idx].material_id = materialIndex;
            newTraceMesh.triangles[tri_idx].V0 = original.vertices[original.triangles[3*tri_idx]];
            newTraceMesh.triangles[tri_idx].E1 = original.vertices[original.triangles[3*tri_idx+1]] - newTraceMesh.triangles[tri_idx].V0;
            newTraceMesh.triangles[tri_idx].E2 = original.vertices[original.triangles[3*tri_idx+2]] - newTraceMesh.triangles[tri_idx].V0;
        }

        newTraceMesh.aabbox = bounding_box;
    
        return newTraceMesh;
    }
}
