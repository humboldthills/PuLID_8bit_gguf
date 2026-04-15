import base64
import os
import shutil
import subprocess
import time

import requests
import runpod

COMFY_URL = "http://127.0.0.1:8188"
COMFY_DIR = "/comfyui"
COMFY_INPUT_DIR = f"{COMFY_DIR}/input"
COMFY_LOG_PATH = "/tmp/comfyui.log"
COMFY_PROCESS = None
EXPECTED_MODEL_FILES = {
    "UnetLoaderGGUF": {"unet_name": "flux1-dev-Q8_0.gguf", "filename": "flux1-dev-Q8_0.gguf"},
    "DualCLIPLoaderGGUF": {
        "clip_name1": "t5-v1_1-xxl-encoder-Q8_0.gguf",
        "clip_name2": "clip_l.safetensors",
        "filename1": "t5-v1_1-xxl-encoder-Q8_0.gguf",
        "filename2": "clip_l.safetensors",
    },
    "VAELoader": {"vae_name": "ae.safetensors", "filename": "ae.safetensors"},
    "PulidFluxModelLoader": {
        "pulid_file": "pulid_flux_v0.9.1.safetensors",
        "filename": "pulid_flux_v0.9.1.safetensors",
    },
}


def launch_comfy():
    global COMFY_PROCESS

    if COMFY_PROCESS and COMFY_PROCESS.poll() is None:
        return

    log_file = open(COMFY_LOG_PATH, "ab")
    COMFY_PROCESS = subprocess.Popen(
        ["python3", "main.py", "--listen", "0.0.0.0", "--port", "8188"],
        cwd=COMFY_DIR,
        stdout=log_file,
        stderr=subprocess.STDOUT,
    )


def wait_for_comfy():
    for _ in range(120):
        try:
            response = requests.get(f"{COMFY_URL}/system_stats", timeout=5)
            response.raise_for_status()
            return True
        except Exception:
            if COMFY_PROCESS and COMFY_PROCESS.poll() is not None:
                break
            time.sleep(1)
    return False


def read_log_tail(max_bytes=12000):
    if not os.path.exists(COMFY_LOG_PATH):
        return ""

    with open(COMFY_LOG_PATH, "rb") as f:
        f.seek(0, os.SEEK_END)
        size = f.tell()
        f.seek(max(0, size - max_bytes))
        return f.read().decode("utf-8", errors="replace")


def get_object_info():
    response = requests.get(f"{COMFY_URL}/object_info", timeout=30)
    response.raise_for_status()
    return response.json()


def get_available_files():
    response = requests.get(f"{COMFY_URL}/models", timeout=30)
    response.raise_for_status()
    return response.json()


def coerce_available_files(data):
    if isinstance(data, dict):
        return data

    if isinstance(data, list):
        normalized = {}
        for item in data:
            if not isinstance(item, dict):
                continue

            model_type = (
                item.get("name")
                or item.get("type")
                or item.get("category")
                or item.get("folder")
            )
            files = item.get("files") or item.get("models") or item.get("items") or []
            if model_type:
                normalized[model_type] = files
        return normalized

    return {}


def normalize_filename(value, candidates):
    if not value or not candidates:
        return value

    if value in candidates:
        return value

    target_name = os.path.basename(value)
    for candidate in candidates:
        if os.path.basename(candidate) == target_name:
            return candidate

    target_stem, target_ext = os.path.splitext(target_name)
    for candidate in candidates:
        stem, ext = os.path.splitext(os.path.basename(candidate))
        if ext == target_ext and stem.startswith(target_stem):
            return candidate

    if "pulid_flux" in target_name:
        for candidate in candidates:
            if "pulid_flux" in os.path.basename(candidate):
                return candidate

    return value


def stage_input_images(job_input):
    os.makedirs(COMFY_INPUT_DIR, exist_ok=True)

    if "input_image_base64" in job_input:
        filename = job_input.get("input_image_name", "input.png")
        with open(os.path.join(COMFY_INPUT_DIR, filename), "wb") as f:
            f.write(base64.b64decode(job_input["input_image_base64"]))

    for image in job_input.get("images", []):
        with open(os.path.join(COMFY_INPUT_DIR, image["name"]), "wb") as f:
            f.write(base64.b64decode(image["base64"]))


def convert_ui_workflow_to_prompt(workflow, object_info):
    link_map = {link[0]: link for link in workflow.get("links", [])}
    prompt = {}

    for node in workflow.get("nodes", []):
        class_type = node["type"]
        node_id = str(node["id"])
        entry = {
            "class_type": class_type,
            "inputs": {},
            "_meta": {
                "title": node.get("title")
                or node.get("properties", {}).get("Node name for S&R", class_type)
            },
        }

        for node_input in node.get("inputs", []):
            link_id = node_input.get("link")
            if link_id is None:
                continue
            link = link_map.get(link_id)
            if link:
                entry["inputs"][node_input["name"]] = [str(link[1]), link[2]]

        class_info = object_info.get(class_type, {})
        ordered_literal_inputs = []
        for section in ("required", "optional"):
            for input_name in class_info.get("input", {}).get(section, {}).keys():
                if input_name not in entry["inputs"]:
                    ordered_literal_inputs.append(input_name)

        for input_name, widget_value in zip(ordered_literal_inputs, node.get("widgets_values", [])):
            entry["inputs"][input_name] = widget_value

        prompt[node_id] = entry

    return prompt


def normalize_prompt_models(prompt, available_files):
    available_files = coerce_available_files(available_files)
    diffusion_models = available_files.get("diffusion_models", [])
    unet_files = available_files.get("unet", [])
    vae_files = available_files.get("vae", [])
    text_encoders = available_files.get("text_encoders", []) or available_files.get("clip", [])
    pulid_files = available_files.get("pulid", [])

    for node in prompt.values():
        class_type = node.get("class_type")
        inputs = node.get("inputs", {})

        for key, expected_value in EXPECTED_MODEL_FILES.get(class_type, {}).items():
            if key in inputs:
                inputs[key] = expected_value

        if class_type == "UnetLoaderGGUF":
            for key in ("unet_name", "filename"):
                if key in inputs:
                    inputs[key] = normalize_filename(inputs[key], unet_files or diffusion_models)

        if class_type == "DualCLIPLoaderGGUF":
            for key in ("clip_name1", "clip_name2", "filename", "filename1", "filename2"):
                if key in inputs:
                    inputs[key] = normalize_filename(inputs[key], text_encoders)

        if class_type == "VAELoader":
            for key in ("vae_name", "filename"):
                if key in inputs:
                    inputs[key] = normalize_filename(inputs[key], vae_files)

        if class_type == "PulidFluxModelLoader":
            for key in ("pulid_file", "filename"):
                if key in inputs:
                    inputs[key] = normalize_filename(inputs[key], pulid_files)


def build_prompt(workflow, object_info):
    if workflow.get("prompt"):
        return workflow["prompt"]
    if workflow.get("nodes"):
        return convert_ui_workflow_to_prompt(workflow, object_info)
    return workflow


def run_workflow(workflow):
    object_info = get_object_info()
    prompt = build_prompt(workflow, object_info)
    try:
        normalize_prompt_models(prompt, get_available_files())
    except Exception as e:
        return {
            "error": "Failed to normalize model filenames",
            "details": str(e),
            "log_tail": read_log_tail(),
        }

    payload = {
        "prompt": prompt,
        "client_id": workflow.get("client_id", "runpod") if isinstance(workflow, dict) else "runpod",
    }

    try:
        response = requests.post(f"{COMFY_URL}/prompt", json=payload, timeout=60)
        response.raise_for_status()
        res = response.json()
    except Exception as e:
        return {
            "error": "ComfyUI returned an invalid response",
            "details": str(e),
            "log_tail": read_log_tail(),
        }

    if "prompt_id" not in res:
        return {
            "error": "ComfyUI rejected the workflow",
            "response": res,
            "log_tail": read_log_tail(),
        }

    prompt_id = res["prompt_id"]

    while True:
        history_response = requests.get(f"{COMFY_URL}/history/{prompt_id}", timeout=30)
        history_response.raise_for_status()
        history = history_response.json()
        if prompt_id in history:
            break
        time.sleep(1)

    prompt_history = history[prompt_id]
    if prompt_history.get("status", {}).get("status_str") == "error":
        return {
            "error": "Workflow execution failed",
            "response": prompt_history,
            "log_tail": read_log_tail(),
        }

    images = []
    for node_id, node_output in prompt_history.get("outputs", {}).items():
        for img in node_output.get("images", []):
            filename = img["filename"]
            subfolder = img.get("subfolder", "")
            folder_type = img.get("type", "output")
            image_response = requests.get(
                f"{COMFY_URL}/view?filename={filename}&subfolder={subfolder}&type={folder_type}",
                timeout=60,
            )
            image_response.raise_for_status()

            images.append(
                {
                    "node_id": node_id,
                    "filename": filename,
                    "base64": base64.b64encode(image_response.content).decode("utf-8"),
                }
            )

    return {
        "prompt_id": prompt_id,
        "images": images,
    }


def handler(job):
    job_input = job.get("input", {})
    workflow = job_input.get("workflow") or job_input.get("prompt")

    if not workflow:
        return {
            "status": "error",
            "error": "Missing workflow or prompt in job.input",
        }

    if job_input.get("copy_input_dir_from"):
        source_dir = job_input["copy_input_dir_from"]
        if os.path.isdir(source_dir):
            os.makedirs(COMFY_INPUT_DIR, exist_ok=True)
            for file_name in os.listdir(source_dir):
                shutil.copy2(
                    os.path.join(source_dir, file_name),
                    os.path.join(COMFY_INPUT_DIR, file_name),
                )

    stage_input_images(job_input)
    launch_comfy()

    if not wait_for_comfy():
        return {
            "status": "error",
            "error": "ComfyUI did not start in time",
            "log_tail": read_log_tail(),
        }

    result = run_workflow(workflow)
    if "error" in result:
        return {
            "status": "error",
            **result,
        }

    return {
        "status": "success",
        **result,
    }


runpod.serverless.start({"handler": handler})
