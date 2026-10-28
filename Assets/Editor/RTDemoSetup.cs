using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;

public static class RTDemoSetup
{
    [MenuItem("RTCore/Prepare Traversal Demo")]
    public static void Prepare()
    {
        var scene = EditorSceneManager.OpenScene("Assets/Scenes/SampleScene.unity");
        foreach (var renderer in Object.FindObjectsByType<FakePGA>(FindObjectsSortMode.None))
            renderer.enabled = false;
        var demo = new GameObject("TI_Shading_Demo").AddComponent<RTTraversalDemo>();
        demo.rtCam = GameObject.FindWithTag("RTcam");
        EditorSceneManager.SaveScene(scene, "Assets/Scenes/TI_Shading_Demo.unity");
    }

    [MenuItem("RTCore/Run Traversal Validation")]
    public static void Test()
    {
        Prepare();
        EditorApplication.isPlaying = true;
        EditorApplication.update += Finish;
    }

    static void Finish()
    {
        if (!EditorApplication.isPlaying) return;
        var demo = Object.FindFirstObjectByType<RTTraversalDemo>();
        if (demo == null || !demo.completed) return;
        EditorApplication.update -= Finish;
        Debug.Log("Traversal validation finished: " + demo.verificationMismatches + " mismatches");
        if (Application.isBatchMode) EditorApplication.Exit(demo.verificationMismatches == 0 ? 0 : 1);
    }
}
