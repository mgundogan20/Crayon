using System.Collections.Generic;
using UnityEngine;

public struct RTRay
{
    public Vector3 origin;
    public Vector3 direction;
    public Vector3 ray_col;
    public Vector3 accum_col;
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

        RTRay[,] rays = GeneratePrimaries(rtCam, fov, X_res, Y_res);
        // Bounce(rays);

        // RenderFrame(rays);
        DrawDebugRays(rays);

        InvokeRepeating("Frame", 0.02f, 0.05f); 
    }

    // Update is called once per frame
    void Update()
    {

    }

    void Frame(){
        Debug.Log("Starting frame");
        RTRay[,] rays = GeneratePrimaries(rtCam, fov, X_res, Y_res);
        Bounce(rays);

        RenderFrame(rays);
    }

    void Bounce(RTRay[,] rays)
    {
        // The following is a very silly way of doing things
        foreach (RTCore_mesh mesh in loadedMeshes){

            string[] geometry = mesh.Serve_Geometry().Split("Triangles:");

            string[] triangles = geometry[1].Split(";", System.StringSplitOptions.RemoveEmptyEntries);

            foreach(string tri in triangles){
                string[] coords = tri.Split(":");
                // Debug.Log(tri);
                Vector3 V0 = ParseVector(coords[0]);
                Vector3 E1 = ParseVector(coords[1]);
                Vector3 E2 = ParseVector(coords[2]);

                for (int x = 0; x < rays.GetLength(0); x++){
                    for (int y = 0; y < rays.GetLength(1); y++){

                        ref RTRay ray = ref rays[x, y];
                        if(CheckIntersection(V0, E1, E2, ray)){
                            ray.accum_col = ray.ray_col;    
                        }
                    }
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

    bool CheckIntersection(Vector3 V0, Vector3 E1, Vector3 E2, RTRay ray)
    {
        const float EPSILON = 1e-7f;

        // Begin calculating determinant; also used for u
        Vector3 P = Vector3.Cross(ray.direction, E2);
        float det = Vector3.Dot(E1, P);

        // Ray is parallel to the triangle plane
        if (det > -EPSILON && det < EPSILON)
            return false;

        float invDet = 1.0f / det;

        // Distance from V0 to ray origin
        Vector3 T = ray.origin - V0;

        // First barycentric coordinate
        float u = Vector3.Dot(T, P) * invDet;
        if (u < 0.0f || u > 1.0f)
            return false;

        // Second barycentric coordinate
        Vector3 Q = Vector3.Cross(T, E1);
        float v = Vector3.Dot(ray.direction, Q) * invDet;
        if (v < 0.0f || u + v > 1.0f)
            return false;

        // Distance along the ray to the hit point
        float t = Vector3.Dot(E2, Q) * invDet;

        // Only count hits in front of the origin
        return t > EPSILON;
    }

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
            
                rays[cur_x, cur_y].origin = camera_origin;
                rays[cur_x, cur_y].direction = direction;

                //TODO: all rays should start white + black
                rays[cur_x, cur_y].ray_col = new Vector3(1, 1, 1);
                rays[cur_x, cur_y].accum_col = new Vector3(0, 0, 0);
            }
        }

        return rays;
    }

    // Debug: one pixel per ray drawn over the Game view
    Texture2D debugTex;

    void RenderFrame(RTRay[,] rays)
    {
        int w = rays.GetLength(0), h = rays.GetLength(1);
        if (debugTex == null || debugTex.width != w || debugTex.height != h)
        {
            debugTex = new Texture2D(w, h, TextureFormat.RGBA32, false);
            debugTex.filterMode = FilterMode.Point;
        }

        Color[] px = new Color[w * h];
        for (int x = 0; x < w; x++)
        {
            for (int y = 0; y < h; y++)
            {
                Vector3 c = rays[x, y].accum_col;
                px[y * w + x] = new Color(c.x, c.y, c.z, 0.3f);
            }
        }
        debugTex.SetPixels(px);
        debugTex.Apply();
    }

    void OnGUI()
    {
        if (debugTex != null)
            GUI.DrawTexture(new Rect(0, 0, Screen.width, Screen.height), debugTex, ScaleMode.ScaleToFit);
    }

    // Debug: draw every stride-th ray in the Scene view, colored by ray_col
    void DrawDebugRays(RTRay[,] rays, int stride = 8, float length = 2.5f, float duration = 100f)
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
}
