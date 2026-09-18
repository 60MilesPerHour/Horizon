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
#
# tensorflow-cpu is needed by onnx2tf, which converts the trained ONNX model
# to tflite. The notebook installs onnx2tf without TensorFlow because Colab
# ships it preinstalled; a slim PyTorch image does not, and the conversion
# fails at the very end of an hour-long run with ModuleNotFoundError. CPU
# build deliberately: the conversion is a graph rewrite, not training.
# tf_keras comes with it because TF 2.16+ ships Keras 3 while onnx2tf still
# imports the Keras 2 API.
#
# openWakeWord's own train.py also tries to export tflite via `onnx_tf`,
# which is abandoned and requires an ancient TensorFlow. That's why the
# notebook comments that path out and shells to onnx2tf instead, and why the
# trainer exits non-zero after successfully writing the .onnx.
#
# scipy<1.15 IS required, unlike the datasets pin below: openWakeWord's
# data.py imports `acoustics`, and acoustics 0.2.6 imports
# scipy.special.sph_harm, which scipy 1.15 removed. acoustics is abandoned at
# 0.2.6, so there's no newer release to move to. scipy 1.14 still supports
# numpy 2.x, so this doesn't drag the rest of the stack backwards.
#
# `datasets` is deliberately NOT pinned to the notebook's 2.14.6. That pin
# drags in pyarrow<15 (2.14.6 uses pa.PyExtensionType, removed in 15), which
# in turn needs numpy<2 for the ABI — a 2023 stack fighting this image's
# numpy 2.1. And it buys nothing: openWakeWord's own training code imports
# neither datasets nor pyarrow. Only this repo's loader uses datasets, for
# `load_dataset(..., streaming=True)` and `cast_column`, both long-stable.
RUN pip install --no-cache-dir \
        piper-tts piper-phonemize-cross webrtcvad \
        mutagen==1.47.0 torchinfo==1.8.0 torchmetrics==1.2.0 \
        speechbrain==0.5.14 audiomentations==0.33.0 \
        torch-audiomentations==0.11.0 acoustics==0.2.6 \
        pronouncing==0.2.0 deep-phonemizer==0.0.19 \
        datasets \
        onnxruntime==1.22.1 ai_edge_litert==1.4.0 onnxsim \
        onnx==1.19.1 onnx2tf onnx_graphsurgeon sng4onnx \
        tensorflow-cpu tf_keras \
        'scipy<1.15' tqdm pyyaml \
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
