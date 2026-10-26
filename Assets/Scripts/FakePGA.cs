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
    public int X_res = 256;
    public int Y_res = 128;

    // Start is called once before the first execution of Update after the MonoBehaviour is created
    void Start()
    {
        // Find all active instances of RTCore_mesh and populate the list
        RTCore_mesh[] foundScripts = Object.FindObjectsByType<RTCore_mesh>(FindObjectsSortMode.None);
        loadedMeshes.AddRange(foundScripts);

        // Optional: Loop through them to do something immediately
        foreach (RTCore_mesh mesh in loadedMeshes)
        {
            Debug.Log(mesh.Serve_Geometry());
        }

        // Hookup the camera with the tag "RTcam" to GeneratePrimaries
        GameObject rtCam = GameObject.FindWithTag("RTcam");
        if (rtCam == null)
        {
            Debug.LogError("FakePGA: no GameObject tagged RTcam found");
            return;
        }

        RTRay[,] rays = GeneratePrimaries(rtCam, fov, X_res, Y_res);
        RenderDebugFrame(rays);
        DrawDebugRays(rays);
    }

    // Update is called once per frame
    void Update()
    {
        
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
                px[y * w + x] = new Color(c.x, c.y, c.z, 1);
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
