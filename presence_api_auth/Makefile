# SAM's makefile build for the cloud recognition functions (template.yaml:
# BuildMethod makefile, CodeUri: this folder). SAM copies this folder and
# runs `make build-<LogicalId>` with ARTIFACTS_DIR set; the jar goes in
# lib/, where the Java runtime finds it. RecognitionFunction compiles
# AuthFunction's sources too (its pom.xml), hence the whole folder.

RECOGNITION_JAR = RecognitionFunction/target/presence-recognition.jar

$(RECOGNITION_JAR):
	mvn -q -B -f RecognitionFunction/pom.xml clean package

build-RecognitionTrainFunction: $(RECOGNITION_JAR)
	mkdir -p "$(ARTIFACTS_DIR)/lib"
	cp $(RECOGNITION_JAR) "$(ARTIFACTS_DIR)/lib/"

build-RecognitionInferFunction: $(RECOGNITION_JAR)
	mkdir -p "$(ARTIFACTS_DIR)/lib"
	cp $(RECOGNITION_JAR) "$(ARTIFACTS_DIR)/lib/"

build-RecognitionDescribeFunction: $(RECOGNITION_JAR)
	mkdir -p "$(ARTIFACTS_DIR)/lib"
	cp $(RECOGNITION_JAR) "$(ARTIFACTS_DIR)/lib/"

.PHONY: build-RecognitionTrainFunction build-RecognitionInferFunction build-RecognitionDescribeFunction
