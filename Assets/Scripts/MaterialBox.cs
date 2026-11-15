using UnityEngine;

// Authoring point for the shared material table. Unity can't serialize statics,
// so Unity materials are assigned here in the Inspector, converted to Mat, and
// copied into RTObject.materials. Index i in unityMaterials == index i in materials.

public class MaterialBox : MonoBehaviour
{
    public Material[] unityMaterials;
    public Mat[] materials;   // derived from unityMaterials (Base Map + Emission Map colors, smoothness)

    static readonly int BaseColorId = Shader.PropertyToID("_BaseColor");
    static readonly int EmissionColorId = Shader.PropertyToID("_EmissionColor");
    static readonly int SmoothnessId = Shader.PropertyToID("_Smoothness");   // URP Lit
    static readonly int GlossinessId = Shader.PropertyToID("_Glossiness");   // Built-in Standard

    void OnValidate()
    {
        FillFromUnityMaterials();
    }

    void Awake()
    {
        FillFromUnityMaterials();
        RTObject.materials.Clear();
        RTObject.materials.AddRange(materials);
    }

    void FillFromUnityMaterials()
    {
        if (unityMaterials == null)
        {
            materials = new Mat[0];
            return;
        }

        materials = new Mat[unityMaterials.Length];
        for (int i = 0; i < unityMaterials.Length; i++)
        {
            Material m = unityMaterials[i];
            if (m == null)
            {
                materials[i] = default;
                continue;
            }

            Color baseCol = m.HasProperty(BaseColorId) ? m.GetColor(BaseColorId) : m.color;
            Color emisCol = m.HasProperty(EmissionColorId) ? m.GetColor(EmissionColorId) : Color.black;
            float smooth = m.HasProperty(SmoothnessId) ? m.GetFloat(SmoothnessId)
                         : m.HasProperty(GlossinessId) ? m.GetFloat(GlossinessId)
                         : 0f;

            materials[i] = new Mat
            {
                diffuseColor = new Vector3(baseCol.r, baseCol.g, baseCol.b),
                emissionColor = new Vector3(emisCol.r, emisCol.g, emisCol.b),
                smoothness = (byte)Mathf.RoundToInt(Mathf.Clamp01(smooth) * 255f)
            };
        }
    }
}
