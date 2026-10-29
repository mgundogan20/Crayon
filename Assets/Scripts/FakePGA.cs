using System.Collections.Generic;
using UnityEngine;

public struct RTRay
{
    public Vector3 origin;
    public Vector3 direction;
    public Vector3 ray_col;
    public Vector3 accum_col;
}

public struct Hit
{
    public float distance;
    public Vector3 position;
    public Vector3 surface_normal;
    public Vector3 diffuseColor;
    public Vector3 emissionColor;
}

public struct Polygon
{
    public Vector3 V0;
    public Vector3 E1;
    public Vector3 E2; 
    public Vector3 diffuseColor;
    public Vector3 emissionColor;
}

public class FakePGA : MonoBehaviour
{

    // A list to hold the found script references
    public List<RTCore_mesh> loadedMeshes = new List<RTCore_mesh>();

    // Primary ray settings
    public float fov = 0.01f;
    public int X_res = 64;
    public int Y_res = 64;

    public GameObject rtCam;
    

    // Start is called once before the first execution of Update after the MonoBehaviour is created
    void Start()
    {
        // Find all active instances of RTCore_mesh and populate the list
        RTCore_mesh[] foundScripts = Object.FindObjectsByType<RTCore_mesh>(FindObjectsSortMode.None);
        loadedMeshes.AddRange(foundScripts);

        // Hookup the camera with the tag "RTcam" to GeneratePrimaries
        rtCam = GameObject.FindWithTag("RTcam");
        if (rtCam == null)
        {
            Debug.LogError("FakePGA: no GameObject tagged RTcam found");
            return;
        }

        // RTRay[,] rays = GeneratePrimaries(rtCam, fov, X_res, Y_res);
        // Bounce(rays);

        // RenderFrame(rays);

        InvokeRepeating("Frame", 0.02f, 0.5f); 
    }

    // Update is called once per frame
    void Update()
    {
        // Frame();
    }

    void Frame(){
        Debug.Log("Starting frame");
        RTRay[,] rays = GeneratePrimaries(rtCam, fov, X_res, Y_res);
        // DrawDebugRays(rays); //Primaries
        Bounce(rays);

        // DrawDebugRays(rays); //Secondaries
        Bounce(rays);
        
        // DrawDebugRays(rays); //Secondaries
        Bounce(rays);
        
        // DrawDebugRays(rays); //Secondaries
        Bounce(rays);
        
        // DrawDebugRays(rays); //Secondaries
        Bounce(rays);

        RenderFrame(rays);
    }

    void Bounce(RTRay[,] rays)
    {
        const float EPSILON = 1e-7f;
        
        // The following is a very silly way of doing things
        
        List<Polygon> tris = new List<Polygon>();

        foreach (RTCore_mesh mesh in loadedMeshes){
            string[] geometry = mesh.Serve_Geometry().Split("Triangles:");

            string[] triangles = geometry[1].Split(";", System.StringSplitOptions.RemoveEmptyEntries);

            foreach(string tri in triangles){
                string[] coords = tri.Split(":");
                // Debug.Log(tri);
                // Vector3 V0 = ParseVector(coords[0]);
                // Vector3 E1 = ParseVector(coords[1]);
                // Vector3 E2 = ParseVector(coords[2]);

                tris.Add(new Polygon{
                    V0 = ParseVector(coords[0]),
                    E1 = ParseVector(coords[1]),
                    E2 = ParseVector(coords[2]),
                    diffuseColor = mesh.materialData.diffuseColor,
                    emissionColor = mesh.materialData.emissionColor
                });
            }
        }

        
        
        for (int x = 0; x < rays.GetLength(0); x++){
            for (int y = 0; y < rays.GetLength(1); y++){
                Hit first_hit;
                first_hit.surface_normal = new Vector3(0,0,0);
                first_hit.emissionColor = new Vector3(0,0,0);
                first_hit.diffuseColor = new Vector3(0,0,0);
                first_hit.position = new Vector3(0,0,0);
                first_hit.distance = 1e10f;

                ref RTRay ray = ref rays[x, y];
                foreach(Polygon t in tris){
                    Hit hit = CheckIntersection(t.V0, t.E1, t.E2, ray);
                    if(hit.distance > EPSILON){
                        if(hit.distance < first_hit.distance){
                            first_hit = hit;
                            first_hit.diffuseColor = t.diffuseColor;
                            first_hit.emissionColor = t.emissionColor;
                        }
                    }
                }

                if(first_hit.distance < 1e9f){
                    ray.accum_col += Vector3.Scale(ray.ray_col, first_hit.emissionColor);
                    ray.ray_col = Vector3.Scale(ray.ray_col, first_hit.diffuseColor);
                    ray.origin = first_hit.position;
                    ray.direction -= first_hit.surface_normal * 2 * Vector3.Dot(ray.direction, first_hit.surface_normal);
                    ray.direction = PerturbDirection(ray.direction, 0.1f);
                }
                else{
                    // Didn't hit, apply skylight
                    ray.accum_col += Vector3.Scale(ray.ray_col, new Vector3(0.8f,0.8f,0.8f));
                    ray.ray_col = new Vector3(0,0,0);
                }
            }
        }

    }

    public Vector3 ParseVector(string input)
    {
        string[] components = input.Trim('(', ')', '[', ']').Replace(" ", "").Split(',');

        float x = float.Parse(components[0]);
        float y = float.Parse(components[1]);
        float z = float.Parse(components[2]);

        return new Vector3(x, y, z);
    }

    Hit CheckIntersection(Vector3 V0, Vector3 E1, Vector3 E2, RTRay ray)
    {
        Hit hit;
        hit.distance = -1;
        hit.position = new Vector3(0,0,0);
        hit.surface_normal = new Vector3(0,0,0);
        hit.diffuseColor = new Vector3(0,0,0);
        hit.emissionColor = new Vector3(0,0,0);
        
        const float EPSILON = 1e-7f;

        // Begin calculating determinant; also used for u
        Vector3 P = Vector3.Cross(ray.direction, E2);
        float det = Vector3.Dot(E1, P);

        // Ray is parallel to the triangle plane
        if (det > -EPSILON && det < EPSILON){
            return hit;
        }

        float invDet = 1.0f / det;

        // Distance from V0 to ray origin
        Vector3 T = ray.origin - V0;

        // First barycentric coordinate
        float u = Vector3.Dot(T, P) * invDet;
        if (u < 0.0f || u > 1.0f){
            return hit;
        }

        // Second barycentric coordinate
        Vector3 Q = Vector3.Cross(T, E1);
        float v = Vector3.Dot(ray.direction, Q) * invDet;
        if (v < 0.0f || u + v > 1.0f){
            return hit;
        }

        // Distance along the ray to the hit point
        hit.distance = Vector3.Dot(E2, Q) * invDet;
        hit.position = ray.origin + hit.distance*ray.direction;
        hit.surface_normal = Vector3.Cross(E1, E2);
        hit.surface_normal /= hit.surface_normal.magnitude;
        return hit;
    }

    //--------------------------------------------------------------

    private RTRay[,] GeneratePrimaries(GameObject camera, float fov, int X_res, int Y_res)
    {
        Vector3 camera_origin = camera.transform.position;
        Vector3 camera_direction = camera.transform.forward;
        Vector3 right = camera.transform.right;
        Vector3 up = camera.transform.up;

        //TODO replace fov with real pixel size calculation
        RTRay[,] rays = new RTRay[X_res, Y_res];

        // TODO: Should be done with matrices
        for(int cur_x=0; cur_x<X_res; cur_x++){
            for(int cur_y=0; cur_y<Y_res; cur_y++){
                float deltax = (cur_x-X_res/2)*fov;
                float deltay = (cur_y-Y_res/2)*fov;
                Vector3 direction = (deltax*right + deltay*up) + camera_direction;
                direction /= direction.magnitude;
            
                rays[cur_x, cur_y].origin = camera_origin;
                rays[cur_x, cur_y].direction = PerturbDirection(direction, 0.002f);

                //TODO: all rays should start white + black
                rays[cur_x, cur_y].ray_col = new Vector3(1, 1, 1);
                rays[cur_x, cur_y].accum_col = new Vector3(0, 0, 0);
            }
        }

        return rays;
    }

    // Debug: one pixel per ray drawn over the Game view
    Texture2D debugTex;
    public int accumFrames = 5;
    Color[] accum;      // running sum of the current batch
    int accumCount = 0;

    void RenderFrame(RTRay[,] rays)
    {
        int w = rays.GetLength(0), h = rays.GetLength(1);
        if (debugTex == null || debugTex.width != w || debugTex.height != h)
        {
            debugTex = new Texture2D(w, h, TextureFormat.RGBA32, false);
            debugTex.filterMode = FilterMode.Point;
            accum = new Color[w * h];   // zero-filled by default
            accumCount = 0;
        }

        Vector3 c;
        for (int x = 0; x < w; x++)
        {
            for (int y = 0; y < h; y++)
            {
                c = rays[x, y].accum_col;
                accum[y * w + x] += new Color(c.x, c.y, c.z, 1.0f);
            }
        }

        if (++accumCount < accumFrames)
            return;

        // Batch complete: show the average, then start a new batch
        float inv = 1.0f / accumCount;
        for (int i = 0; i < accum.Length; i++)
            accum[i] *= inv;
        debugTex.SetPixels(accum);
        debugTex.Apply();

        System.Array.Clear(accum, 0, accum.Length);
        accumCount = 0;
    }

    void OnGUI()
    {
        if (debugTex != null)
            GUI.DrawTexture(new Rect(0, 0, Screen.width, Screen.height), debugTex, ScaleMode.ScaleToFit);
    }

    // Debug: draw every stride-th ray in the Scene view, colored by ray_col
    void DrawDebugRays(RTRay[,] rays, int stride = 40, float length = 0.25f, float duration = 10.0f)
    {
        for (int x = 0; x < rays.GetLength(0); x += stride)
        {
            for (int y = 0; y < rays.GetLength(1); y += stride)
            {
                Vector3 c = rays[x, y].ray_col;
                Debug.DrawRay(rays[x, y].origin, rays[x, y].direction.normalized * length, new Color(c.x, c.y, c.z), duration);
            }
        }
    }

    public static Vector3 PerturbDirection(Vector3 initial, float maxAngleRad)
    {
        // Get angle from z
        float cosTheta = Random.Range(Mathf.Cos(maxAngleRad), 1f);
        float sinTheta = Mathf.Sqrt(1f - cosTheta * cosTheta);

        // Get angle from x
        float phi = Random.Range(0f, 2*Mathf.PI);

        // Convert to cartesian
        Vector3 localDir = new Vector3(
            sinTheta * Mathf.Cos(phi),
            cosTheta,
            sinTheta * Mathf.Sin(phi)
        );

        // Rotation maps z axis to initial direction
        Quaternion rotationToNormal = Quaternion.FromToRotation(Vector3.up, initial);

        // Rotate to align
        return rotationToNormal * localDir;
    }

}
