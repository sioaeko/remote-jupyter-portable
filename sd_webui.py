import torch
import gradio as gr
from diffusers import StableDiffusionPipeline

MODELS = {
    "Anything V5 (애니/일러스트)": "stablediffusionapi/anything-v5",
    "DreamShaper 8 (만능)": "Lykon/dreamshaper-8",
    "Realistic Vision 5.1 (실사)": "SG161222/Realistic_Vision_V5.1_noVAE",
    "OpenJourney V4 (Midjourney풍)": "prompthero/openjourney-v4",
}

current = {"name": None, "pipe": None}

def load_model(name):
    if current["name"] == name:
        return current["pipe"]
    if current["pipe"] is not None:
        del current["pipe"]
        torch.cuda.empty_cache()
    print(f"Loading {name}...")
    pipe = StableDiffusionPipeline.from_pretrained(
        MODELS[name],
        torch_dtype=torch.float16,
        safety_checker=None,
    ).to("cuda")
    pipe.enable_attention_slicing()
    current["name"] = name
    current["pipe"] = pipe
    print(f"Ready! VRAM: {torch.cuda.memory_allocated() / 1024**2:.0f} MB")
    return pipe

def generate(model_name, prompt, negative_prompt, steps, guidance, width, height, seed):
    pipe = load_model(model_name)
    generator = torch.Generator("cuda").manual_seed(int(seed)) if seed >= 0 else None
    image = pipe(
        prompt,
        negative_prompt=negative_prompt or None,
        num_inference_steps=int(steps),
        guidance_scale=guidance,
        width=int(width),
        height=int(height),
        generator=generator,
    ).images[0]
    return image

with gr.Blocks(title="SD WebUI") as demo:
    gr.Markdown("# Stable Diffusion WebUI")
    with gr.Row():
        with gr.Column():
            model_dd = gr.Dropdown(list(MODELS.keys()), value="Anything V5 (애니/일러스트)", label="모델")
            prompt = gr.Textbox(label="프롬프트", lines=3, placeholder="masterpiece, best quality, ...")
            neg_prompt = gr.Textbox(label="네거티브 프롬프트", lines=2, value="lowres, bad anatomy, worst quality, low quality")
            with gr.Row():
                steps = gr.Slider(10, 50, value=25, step=1, label="Steps")
                guidance = gr.Slider(1, 20, value=7.5, step=0.5, label="CFG Scale")
            with gr.Row():
                width = gr.Slider(256, 1024, value=512, step=64, label="Width")
                height = gr.Slider(256, 1024, value=512, step=64, label="Height")
            seed = gr.Number(value=-1, label="Seed (-1 = 랜덤)", precision=0)
            btn = gr.Button("생성", variant="primary")
        with gr.Column():
            output = gr.Image(label="결과")
    btn.click(generate, [model_dd, prompt, neg_prompt, steps, guidance, width, height, seed], output)

demo.launch(share=True)
