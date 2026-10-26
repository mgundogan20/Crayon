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
    public Triangle[] triangles;
}

[System.Serializable]
public struct Mat
{
    public Color diffuseColor;
    public Color emissionColor;
}

public class RTCore_mesh : MonoBehaviour
{
    public Mesh meshData;
    public Mat materialData;

    public RTMesh rtMesh;

    public int myfav;

    public int objectID;

    public string objectName;

    // Start is called once before the first execution of Update after the MonoBehaviour is created
    void Start()
    {
        meshData.meshFilter = GetComponent<MeshFilter>();

        // Load the vertices of the mesh 
        meshData.vertices = meshData.meshFilter.mesh.vertices;
        meshData.triangles = meshData.meshFilter.mesh.triangles;

        rtMesh = Convert_mesh(meshData);
    }

    // Update is called once per frame
    void Update()
    {
        // Print the vertices and triangles of the mesh as a single string every 10 seconds
        if (Time.time % 10 < Time.deltaTime)
        {
            string meshInfo = "Object ID: " + objectID + ", Name: " + objectName + "\nVertices\n: ";

            foreach (Triangle tri in rtMesh.triangles)
            {
                meshInfo += "V0: ";
                meshInfo += tri.V0.ToString() + " E1-E2: ";
                meshInfo += tri.E1.ToString() + ", ";
                meshInfo += tri.E2.ToString() + "\n";
            }

            Debug.Log(meshInfo);
        }
    }

    RTMesh Convert_mesh(Mesh original)
    {
        int triangle_count = original.triangles.Length / 3;

        RTMesh rTMesh;
        rTMesh.triangles = new Triangle[triangle_count];

        for(int tri_idx = 0; tri_idx < triangle_count ;tri_idx += 1)
        {
            rTMesh.triangles[tri_idx].V0 = original.vertices[original.triangles[3*tri_idx]];
            rTMesh.triangles[tri_idx].E1 = original.vertices[original.triangles[3*tri_idx+1]] - rTMesh.triangles[tri_idx].V0;
            rTMesh.triangles[tri_idx].E2 = original.vertices[original.triangles[3*tri_idx+2]] - rTMesh.triangles[tri_idx].V0;
        }
    
        return rTMesh;
    }
}
