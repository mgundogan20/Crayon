using UnityEngine;
[System.Serializable]

public struct Triangle
{
    public int placeholder;
    public Vector3 V0;
    public Vector3 E1;
    public Vector3 E2; 
}

public struct Mesh
{
    public MeshFilter meshFilter;
    public Vector3[] vertices;
    public int[] triangles;
}

public struct RTMesh
{
    // TODO: Triangle could be 3 indices to arrays of V0[] + E[]
    public Triangle[] triangles;

    public int tri_count;
}


[System.Serializable]
public struct Mat
{
    public Vector3 diffuseColor;
    public Vector3 emissionColor;
}

public class RTCore_mesh : MonoBehaviour
{
    public Mesh meshData;
    public Mat materialData;

    public RTMesh rtMesh;

    public Transform obj_transform;

    public int objectID;

    public string objectName;

    // Awake runs before any Start, so geometry is ready when other scripts query it in their Start
    void Awake()
    {
        meshData.meshFilter = GetComponent<MeshFilter>();
        obj_transform = GetComponent<Transform>();

        // Load the vertices of the mesh 
        meshData.vertices = meshData.meshFilter.mesh.vertices;
        meshData.triangles = meshData.meshFilter.mesh.triangles;
    }

    // Update is called once per frame
    void Update()
    {
        obj_transform.TransformPoints(meshData.meshFilter.mesh.vertices, meshData.vertices);
        rtMesh = Convert_mesh(meshData);
    }

    private RTMesh Convert_mesh(Mesh original)
    {
        int triangle_count = original.triangles.Length / 3;

        RTMesh newRTMesh;
        newRTMesh.tri_count = triangle_count;
        newRTMesh.triangles = new Triangle[triangle_count];

        for(int tri_idx = 0; tri_idx < triangle_count ;tri_idx += 1)
        {
            newRTMesh.triangles[tri_idx].V0 = original.vertices[original.triangles[3*tri_idx]];
            newRTMesh.triangles[tri_idx].E1 = original.vertices[original.triangles[3*tri_idx+1]] - newRTMesh.triangles[tri_idx].V0;
            newRTMesh.triangles[tri_idx].E2 = original.vertices[original.triangles[3*tri_idx+2]] - newRTMesh.triangles[tri_idx].V0;
        }
    
        return newRTMesh;
    }

    public string Serve_Geometry()
    {
        // TODO does not need to be human readible for the real application
        var sb = new System.Text.StringBuilder();
        sb.Append("Object ID: ").Append(objectID);
        sb.Append(", Name: ").Append(objectName).Append('\n');

        sb.Append("N: ").Append(rtMesh.tri_count);

        sb.Append("\nEm").Append(materialData.emissionColor.ToString());
        sb.Append("\nAb").Append(materialData.diffuseColor.ToString());
        
        sb.Append("\nTriangles:");
        foreach (Triangle tri in rtMesh.triangles){
            sb.Append(tri.V0.ToString("R")).Append(':');
            sb.Append(tri.E1.ToString("R")).Append(':');
            sb.Append(tri.E2.ToString("R")).Append(';');
        }

        return sb.ToString();
    }
}
