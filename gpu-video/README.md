# GPU video generation on AWS (ComfyUI + Wan 2.2)

One CloudFormation stack that gives you:

- **GPU**: `g6e.2xlarge` by default (NVIDIA L40S, 48 GB VRAM, 64 GB RAM, about $2.24/hr on demand in us-east-1)
- **Software**: [ComfyUI](https://github.com/comfyanonymous/ComfyUI), ComfyUI-Manager and VideoHelperSuite, running as a systemd service
- **Models**: [Wan 2.2](https://github.com/Wan-Video/Wan2.2), open weights under Apache 2.0, run locally with no hosted filter:
  - 14B text-to-video and 14B image-to-video (fp8, high-noise and low-noise experts)
  - 5B text/image-to-video (faster, lighter)
  - lightx2v 4-step LoRAs, which make generation about 5–10× faster
- **Safety for your wallet**: stops itself after 60 min with no GPU work. Disk and models persist across stop/start.
- **Security**: ComfyUI has no login, so it listens on localhost only. You reach it through an SSM tunnel, and no ports are open to the internet.

## One-time prerequisites

1. **GPU quota.** New accounts have 0 GPU vCPUs. In the console, open Service Quotas → EC2 → *Running On-Demand G and VT instances* and request **8** (16 for g6e.4xlarge). Approval usually takes minutes to a day.
2. **Local tools**: [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) and the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html). Run `aws configure` with credentials that can create IAM roles, EC2 and CloudFormation resources.
3. Your region needs a default VPC. Most accounts already have one.

## Use it

```bash
cd gpu-video
./gpu.sh deploy                                   # ~3 min to launch, then ~15-30 min installing + downloading ~85GB
./gpu.sh logs                                     # watch bootstrap; done when it prints "ComfyUI bootstrap complete"
./gpu.sh tunnel                                   # then open http://localhost:8188
```

In ComfyUI, open **Workflow → Browse Templates → Video** and pick a *Wan 2.2* template, for example "Wan 2.2 14B Text to Video". The models are already in place, so type your prompt and click **Run**. Generated videos are saved to `~/ComfyUI/output` on the instance, and you can also download them from the UI.

Day to day:

```bash
./gpu.sh start      # after it auto-stopped (≈1 min to boot, ComfyUI starts automatically)
./gpu.sh stop       # stop paying for GPU (disk still costs ~$20/month for 250GB)
./gpu.sh destroy    # delete everything
```

### Options

Pass CloudFormation overrides to `deploy`:

```bash
./gpu.sh deploy InstanceType=g6e.4xlarge IdleStopMinutes=120
./gpu.sh deploy InstanceType=g5.2xlarge ModelSet=wan22-5b        # cheaper 24GB GPU, 5B model
./gpu.sh deploy KeyName=my-key SshCidr=$(curl -s ifconfig.me)/32 # also allow SSH
```

| Parameter | Default | Notes |
|---|---|---|
| `InstanceType` | `g6e.2xlarge` | `g6e.xlarge`, `g6e.4xlarge`, `g5.2xlarge`, `p5.4xlarge` (H100, needs *P instances* quota) |
| `ModelSet` | `wan22-all` | `wan22-14b`, `wan22-5b` |
| `AdultModels` | `false` | `true` adds Wan 2.2 Remix NSFW (T2V + I2V) and its NSFW text encoder (~64GB) |
| `VolumeSizeGiB` | `250` | |
| `IdleStopMinutes` | `60` | `0` disables auto-stop |
| `KeyName` / `SshCidr` | empty | Optional SSH access |

Set `STACK=name` or `AWS_REGION=...` before `./gpu.sh` to run a second stack or use another region.

### Rough speeds on an L40S

- 5B, 720p, 5 s clip: about 3–5 min
- 14B with the 4-step LoRA, 480p–720p, 5 s clip: about 2–6 min
- 14B without the LoRA, 720p: 20+ min

### Adult content (`AdultModels=true`)

Base Wan 2.2 never refuses a prompt, but it saw little explicit material in training, so it renders it poorly. [Wan 2.2 Remix](https://huggingface.co/FX-FeiHou/wan2.2-Remix) is a community fine-tune for this. To use it:

1. Load the stock Wan 2.2 14B template.
2. In the two *Load Diffusion Model* nodes, pick `Wan2.2_Remix_NSFW_{t2v|i2v}_14b_{high|low}_lighting_*`.
3. In *Load CLIP*, pick `nsfw_wan_umt5-xxl_fp8_scaled`.
4. Remove the lightx2v LoRAs. The 4-step speed-up is already built in, so use about 4–8 steps and CFG 1.

For image-to-video, upload a starting image, for example a photo of yourself. Only use photos of people who consented, and only of adults.

Install more models or custom nodes from **Manager** in the ComfyUI menu.

## Troubleshooting

- **`deploy` fails with `VcpuLimitExceeded` or `InsufficientInstanceCapacity`**: request the quota increase from prerequisite 1. If AWS has no capacity, try another region with `AWS_REGION=us-west-2 ./gpu.sh deploy`.
- **Tunnel fails right after deploy**: the SSM agent needs a minute or two to register.
- **Out-of-memory on the GPU**: use the 5B model, lower the resolution or frame count, or switch to a larger instance.
- **Where things are on the instance**: ComfyUI is in `~/ComfyUI` (`sudo systemctl restart comfyui`), and the bootstrap log is `/var/log/comfyui-bootstrap.log`.
