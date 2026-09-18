# openWakeWord custom model training, on your own GPU instead of Colab.
#
# The base image is the whole point. The notebook does:
#
#   pip install torch==2.5.0 ... --index-url .../whl/cu121
#
# which is a resolution fight it loses as soon as the host Python or CUDA
# moves — and Colab has since moved to Python 3.12, while the notebook's own
# comments say the ONNX -> tflite step "works for python 3.11". So: pin the
# environment by picking an image that already has the right torch, CUDA and
# Python, and never pass --index-url at all.
FROM pytorch/pytorch:2.5.1-cuda12.1-cudnn9-devel

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    # The notebook overrides this in Python because Colab's locale breaks
    # HuggingFace downloads; setting it properly is cleaner.
    LC_ALL=C.UTF-8 \
    LANG=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
        git git-lfs wget curl ca-certificates ffmpeg libsndfile1 \
    && git lfs install \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work

# Sample generation (Piper) and the openWakeWord training code.
RUN git clone https://github.com/rhasspy/piper-sample-generator \
    && cd piper-sample-generator \
    && git checkout 213d4d5 \
    && wget -q -O models/en_US-libritts_r-medium.pt \
        'https://github.com/rhasspy/piper-sample-generator/releases/download/v2.0.0/en_US-libritts_r-medium.pt'

RUN git clone https://github.com/dscripka/openwakeword

# Split from the clone so a dependency change doesn't re-clone, and pinned to
# the notebook's versions — these are what the training code is written
# against, and unpinning them is how you get errors deep inside speechbrain.
RUN pip install --no-cache-dir \
        piper-tts piper-phonemize-cross webrtcvad \
        mutagen==1.47.0 torchinfo==1.8.0 torchmetrics==1.2.0 \
        speechbrain==0.5.14 audiomentations==0.33.0 \
        torch-audiomentations==0.11.0 acoustics==0.2.6 \
        pronouncing==0.2.0 datasets==2.14.6 deep-phonemizer==0.0.19 \
        onnxruntime==1.22.1 ai_edge_litert==1.4.0 onnxsim \
        onnx==1.19.1 onnx2tf onnx_graphsurgeon sng4onnx \
        scipy tqdm pyyaml \
    && pip install --no-cache-dir -e ./openwakeword --no-deps

# openWakeWord's shared feature models. The notebook fetches these as a
# "workaround for Colab"; they're needed everywhere, so bake them in.
RUN mkdir -p /work/openwakeword/openwakeword/resources/models && cd /work/openwakeword/openwakeword/resources/models \
    && for f in embedding_model.onnx embedding_model.tflite melspectrogram.onnx melspectrogram.tflite; do \
         wget -q "https://github.com/dscripka/openWakeWord/releases/download/v0.5.1/$f" -O "$f"; \
       done

COPY train.py /work/train.py
COPY preview.py /work/preview.py

ENTRYPOINT ["python", "/work/train.py"]
