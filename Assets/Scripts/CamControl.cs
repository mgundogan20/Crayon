using UnityEngine;
using UnityEngine.InputSystem;

public class CamControl : MonoBehaviour
{
    public float sensitivity = 0.001f; // Adjusted for raw mouse delta
    public float normalSpeed = 1.0f;
    public float sprintSpeed = 10.0f;

    private float rotationX = 0.0f;
    private float rotationY = 0.0f;

    void Start()
    {
        Vector3 rot = transform.localEulerAngles;
        rotationX = rot.y;
        rotationY = rot.x;
        Cursor.lockState = CursorLockMode.Locked;
    }

    void Update()
    {
        var mouse = Mouse.current;
        var keyboard = Keyboard.current;

        // Safety check in case hardware isn't detected
        if (mouse == null || keyboard == null) return;

        // Mouse Look
        Vector2 mouseDelta = mouse.delta.ReadValue();
        rotationX += mouseDelta.x * sensitivity;
        rotationY -= mouseDelta.y * sensitivity;
        rotationY = Mathf.Clamp(rotationY, -90f, 90f);

        transform.localRotation = Quaternion.Euler(rotationY, rotationX, 0.0f);

        // Movement Speed
        float currentSpeed = keyboard.leftShiftKey.isPressed ? sprintSpeed : normalSpeed;

        // WASD / Q / E Movement
        Vector3 moveInput = Vector3.zero;
        if (keyboard.wKey.isPressed) moveInput.z += 1.0f;
        if (keyboard.sKey.isPressed) moveInput.z -= 1.0f;
        if (keyboard.dKey.isPressed) moveInput.x += 1.0f;
        if (keyboard.aKey.isPressed) moveInput.x -= 1.0f;
        if (keyboard.eKey.isPressed) moveInput.y += 1.0f;
        if (keyboard.qKey.isPressed) moveInput.y -= 1.0f;

        Vector3 moveDirection = (transform.forward * moveInput.z + transform.right * moveInput.x + transform.up * moveInput.y).normalized;
        transform.position += moveDirection * currentSpeed * Time.deltaTime;

        // Unlock cursor with Escape key
        if (keyboard.escapeKey.wasPressedThisFrame)
        {
            Cursor.lockState = CursorLockMode.None;
        }
    }
}
