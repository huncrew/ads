#!/bin/bash
# SageMaker Studio JupyterLab lifecycle config: installs ComfyUI + Wan 2.2 models on
# first start (persisted in the space's EBS home) and launches ComfyUI on :8188 every start.
# Reach it at https://<studio-domain>/jupyterlab/default/proxy/8188/
# Log: ~/comfyui-setup.log
# LCC scripts must finish within a few minutes, so all work runs in the background.
set -eu
nohup bash -c '
set -euxo pipefail
C=$HOME/ComfyUI
M=$C/models
ADULT_MODELS=true

if [ ! -f $C/.installed ]; then
  [ -d $C ] || git clone https://github.com/comfyanonymous/ComfyUI.git $C
  [ -d $C/custom_nodes/ComfyUI-Manager ] || git clone https://github.com/ltdrdata/ComfyUI-Manager.git $C/custom_nodes/ComfyUI-Manager
  [ -d $C/custom_nodes/ComfyUI-VideoHelperSuite ] || git clone https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git $C/custom_nodes/ComfyUI-VideoHelperSuite
  [ -d $C/venv ] || python3 -m venv $C/venv
  $C/venv/bin/pip install -q --upgrade pip
  $C/venv/bin/pip install -q torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu128
  $C/venv/bin/pip install -q -r $C/requirements.txt \
    -r $C/custom_nodes/ComfyUI-Manager/requirements.txt \
    -r $C/custom_nodes/ComfyUI-VideoHelperSuite/requirements.txt imageio-ffmpeg
  touch $C/.installed
fi

# Each app start is a fresh container, so no old ComfyUI process to stop.
cd $C && nohup $C/venv/bin/python $C/main.py --listen 127.0.0.1 --port 8188 > $HOME/comfyui.log 2>&1 &

# Models: download anything missing (resumable), 4 at a time.
HF=https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files
R=https://huggingface.co/FX-FeiHou/wan2.2-Remix/resolve/main/NSFW
{
  echo "$HF/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors text_encoders"
  echo "$HF/vae/wan_2.1_vae.safetensors vae"
  echo "$HF/vae/wan2.2_vae.safetensors vae"
  echo "$HF/diffusion_models/wan2.2_ti2v_5B_fp16.safetensors diffusion_models"
  for m in t2v_high_noise t2v_low_noise i2v_high_noise i2v_low_noise; do
    echo "$HF/diffusion_models/wan2.2_${m}_14B_fp8_scaled.safetensors diffusion_models"
  done
  echo "$HF/loras/wan2.2_t2v_lightx2v_4steps_lora_v1.1_high_noise.safetensors loras"
  echo "$HF/loras/wan2.2_t2v_lightx2v_4steps_lora_v1.1_low_noise.safetensors loras"
  echo "$HF/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_high_noise.safetensors loras"
  echo "$HF/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_low_noise.safetensors loras"
  if [ "$ADULT_MODELS" = true ]; then
    for f in i2v_14b_high_lighting_fp8_e4m3fn_v3.0 i2v_14b_low_lighting_fp8_e4m3fn_v3.0 \
             t2v_14b_high_lighting_v2.0 t2v_14b_low_lighting_v2.0; do
      echo "$R/Wan2.2_Remix_NSFW_$f.safetensors diffusion_models"
    done
    echo "https://huggingface.co/NSFW-API/NSFW-Wan-UMT5-XXL/resolve/main/nsfw_wan_umt5-xxl_fp8_scaled.safetensors text_encoders"
  fi
} | while read -r url dir; do
  f=$M/$dir/${url##*/}
  [ -f "$f" ] || echo "$url $f"
done | xargs -r -P 4 -n 2 sh -c "mkdir -p \$(dirname \$1) && curl -fsSL --retry 10 -C - -o \$1.part \$0 && mv \$1.part \$1" || true
echo "ComfyUI setup complete"
' > "$HOME/comfyui-setup.log" 2>&1 &
disown
