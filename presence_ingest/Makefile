# sam build's makefile build (template.yaml): the function's code, its
# dependencies as Linux arm64 wheels for Python 3.13 (whatever machine
# builds it), and the detector's model, which scripts/deploy.sh downloads
# into IngestFunction/models first (scripts/models.sh, checked by SHA-256).
PIP ?= python3 -m pip

build-IngestFunction:
	test -f IngestFunction/models/yolov4-tiny.weights || { echo "no model: run bash scripts/models.sh presence_ingest/IngestFunction/models" >&2; exit 1; }
	$(PIP) install --quiet --no-compile --target "$(ARTIFACTS_DIR)" \
		--platform manylinux2014_aarch64 --platform manylinux_2_28_aarch64 \
		--python-version 3.13 --implementation cp --only-binary=:all: \
		-r IngestFunction/requirements.txt
	cp -R IngestFunction/ingest "$(ARTIFACTS_DIR)/ingest"
	mkdir -p "$(ARTIFACTS_DIR)/models"
	cp IngestFunction/models/yolov4-tiny.cfg IngestFunction/models/yolov4-tiny.weights "$(ARTIFACTS_DIR)/models/"
