import runpod
import requests
import time
import base64
import os
import json

COMFY_URL = "http://127.0.0.1:8188"

# Wait for ComfyUI to be ready
def wait_for_comfy():
    for _ in range(60):
        try:
            requests.get(f"{COMFY_URL}/system_stats")
            return True
        except:
            time.sleep(1)
    return False


def run_workflow(workflow):
    # 1. Submit workflow to ComfyUI
    prompt = {"prompt": workflow}
    res = requests.post(f"{COMFY_URL}/prompt", json=prompt).json()
    prompt_id = res["prompt_id"]

    # 2. Poll for result
    while True:
        history = requests.get(f"{COMFY_URL}/history/{prompt_id}").json()
        if prompt_id in history:
            break
        time.sleep(1)

    output = history[prompt_id]["outputs"]

    # 3. Extract image(s)
    images = []
    for node_id, node_output in output.items():
        if "images" in node_output:
            for img in node_output["images"]:
                filename = img["filename"]
                subfolder = img.get("subfolder", "")
                folder_type = img.get("type", "output")

                # 4. Fetch image bytes
                img_bytes = requests.get(
                    f"{COMFY_URL}/view?filename={filename}&subfolder={subfolder}&type={folder_type}"
                ).content

                # 5. Convert to base64
                images.append({
                    "filename": filename,
                    "base64": base64.b64encode(img_bytes).decode("utf-8")
                })

    return images


def handler(job):
    workflow = job["input"]["workflow"]

    # Ensure ComfyUI is up
    if not wait_for_comfy():
        return {"error": "ComfyUI did not start in time"}

    # Run the workflow
    images = run_workflow(workflow)

    return {
        "status": "success",
        "images": images
    }


runpod.serverless.start({"handler": handler})
