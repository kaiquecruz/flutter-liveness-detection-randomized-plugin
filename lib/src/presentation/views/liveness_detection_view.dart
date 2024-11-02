// ignore_for_file: depend_on_referenced_packages
import 'package:flutter/foundation.dart';
import 'package:flutter_liveness_detection_randomized_plugin/index.dart';
import 'package:flutter_liveness_detection_randomized_plugin/src/core/constants/liveness_detection_step_constant.dart';

List<CameraDescription> availableCams = [];

class LivenessDetectionView extends StatefulWidget {
  final LivenessDetectionConfig config;
  final bool isEnableSnackBar;
  final bool shuffleListWithSmileLast;

  const LivenessDetectionView({
    super.key,
    required this.config,
    required this.isEnableSnackBar,
    this.shuffleListWithSmileLast = true,
  });

  @override
  State<LivenessDetectionView> createState() => _LivenessDetectionScreenState();
}

class _LivenessDetectionScreenState extends State<LivenessDetectionView> {
  // Camera related variables
  CameraController? _cameraController;
  int _cameraIndex = 0;
  bool _isBusy = false;
  bool _isTakingPicture = false;
  Timer? _timerToDetectFace;

  // Detection state variables
  late bool _isInfoStepCompleted;
  bool _isProcessingStep = false;
  bool _didCloseEyes = false;
  bool _faceDetectedState = false;

  // Steps related variables
  late final List<LivenessDetectionStepItem> steps;
  final GlobalKey<LivenessDetectionStepOverlayWidgetState> _stepsKey =
      GlobalKey<LivenessDetectionStepOverlayWidgetState>();

  static void shuffleListLivenessChallenge({
    required List<LivenessDetectionStepItem> list,
    required bool isSmileLast,
  }) {
    if (isSmileLast) {
      int? blinkIndex =
          list.indexWhere((item) => item.title == "Blink 2-3 Times");
      int? smileIndex = list.indexWhere((item) => item.title == "Smile");

      if (blinkIndex != -1 && smileIndex != -1) {
        LivenessDetectionStepItem blinkItem = list.removeAt(blinkIndex);
        LivenessDetectionStepItem smileItem = list
            .removeAt(smileIndex > blinkIndex ? smileIndex - 1 : smileIndex);
        list.shuffle(Random());
        list.insert(list.length - 1, blinkItem);
        list.add(smileItem);
      } else {
        list.shuffle(Random());
      }
    } else {
      list.shuffle(Random());
    }
  }

  @override
  void initState() {
    _preInitCallBack();
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _postFrameCallBack());
    shuffleListLivenessChallenge(
        list: stepLiveness, isSmileLast: widget.shuffleListWithSmileLast);
  }

  @override
  void dispose() {
    _timerToDetectFace?.cancel();
    _timerToDetectFace = null;
    _cameraController?.dispose();
    shuffleListLivenessChallenge(
        list: stepLiveness, isSmileLast: widget.shuffleListWithSmileLast);
    super.dispose();
  }

  void _preInitCallBack() {
  
    _isInfoStepCompleted = !widget.config.startWithInfoScreen;
  }

  void _postFrameCallBack() async {
    availableCams = await availableCameras();
    if (availableCams.any((element) =>
        element.lensDirection == CameraLensDirection.front &&
        element.sensorOrientation == 90)) {
      _cameraIndex = availableCams.indexOf(
        availableCams.firstWhere((element) =>
            element.lensDirection == CameraLensDirection.front &&
            element.sensorOrientation == 90),
      );
    } else {
      _cameraIndex = availableCams.indexOf(
        availableCams.firstWhere(
            (element) => element.lensDirection == CameraLensDirection.front),
      );
    }
    if (!widget.config.startWithInfoScreen) {
      _startLiveFeed();
    }
  }

  void _startLiveFeed() async {
    final camera = availableCams[_cameraIndex];
    _cameraController =
        CameraController(camera, ResolutionPreset.high, enableAudio: false);

    _cameraController?.initialize().then((_) {
      if (!mounted) return;
      _cameraController?.startImageStream(_processCameraImage);
      setState(() {});
    });
    _startFaceDetectionTimer();
  }

  void _startFaceDetectionTimer() {
    _timerToDetectFace = Timer(const Duration(seconds: 45),
        () => _onDetectionCompleted(imgToReturn: null));
  }

  Future<void> _processCameraImage(CameraImage cameraImage) async {
    final WriteBuffer allBytes = WriteBuffer();
    for (final Plane plane in cameraImage.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final bytes = allBytes.done().buffer.asUint8List();

    final Size imageSize = Size(
      cameraImage.width.toDouble(),
      cameraImage.height.toDouble(),
    );

    final camera = availableCams[_cameraIndex];
    final imageRotation =
        InputImageRotationValue.fromRawValue(camera.sensorOrientation);
    if (imageRotation == null) return;

    final inputImageFormat =
        InputImageFormatValue.fromRawValue(cameraImage.format.raw);
    if (inputImageFormat == null) return;

    final inputImageData = InputImageMetadata(
      size: imageSize,
      rotation: imageRotation,
      format: inputImageFormat,
      bytesPerRow: cameraImage.planes[0].bytesPerRow,
    );

    final inputImage = InputImage.fromBytes(
      metadata: inputImageData,
      bytes: bytes,
    );

    _processImage(inputImage);
  }

  Future<void> _processImage(InputImage inputImage) async {
    if (_isBusy) return;
    _isBusy = true;

    final faces =
        await MachineLearningKitHelper.instance.processInputImage(inputImage);

    if (inputImage.metadata?.size != null &&
        inputImage.metadata?.rotation != null) {
      if (faces.isEmpty) {
        _resetSteps();
        setState(() => _faceDetectedState = false);
      } else {
        setState(() => _faceDetectedState = true);

        if (_isProcessingStep &&
            stepLiveness[_stepsKey.currentState?.currentIndex ?? 0].step ==
                LivenessDetectionStep.blink) {
          if (_didCloseEyes) {
            if ((faces.first.leftEyeOpenProbability ?? 1.0) < 0.75 &&
                (faces.first.rightEyeOpenProbability ?? 1.0) < 0.75) {
              await _completeStep(
                  step: stepLiveness[_stepsKey.currentState?.currentIndex ?? 0].step);
            }
          }
        }
        _detectFace(
          face: faces.first,
          step: stepLiveness[_stepsKey.currentState?.currentIndex ?? 0].step,
        );
      }
    } else {
      _resetSteps();
    }

    _isBusy = false;
    if (mounted) setState(() {});
  }

  void _detectFace({
    required Face face,
    required LivenessDetectionStep step,
  }) async {
    if (_isProcessingStep) return;

    switch (step) {
      case LivenessDetectionStep.blink:
        await _handlingBlinkStep(face: face);
        break;

      case LivenessDetectionStep.lookRight:
        await _handlingTurnRight(face: face, step: step);
        break;

      case LivenessDetectionStep.lookLeft:
        await _handlingTurnLeft(face: face, step: step);
        break;

      case LivenessDetectionStep.lookUp:
        await _handlingLookUp(face: face, step: step);
        break;

      case LivenessDetectionStep.lookDown:
        await _handlingLookDown(face: face, step: step);
        break;

      case LivenessDetectionStep.smile:
        await _handlingSmile(face: face, step: step);
        break;
    }
  }

  Future<void> _completeStep({required LivenessDetectionStep step}) async {
    if (mounted) setState(() {});
    await _stepsKey.currentState?.nextPage();
    _stopProcessing();
  }

  void _takePicture() async {
    try {
      if (_cameraController == null || _isTakingPicture) return;

      setState(() => _isTakingPicture = true);
      await _cameraController?.stopImageStream();

      final XFile? clickedImage = await _cameraController?.takePicture();
      if (clickedImage == null) {
        _startLiveFeed();
        return;
      }

      _onDetectionCompleted(imgToReturn: clickedImage);
    } catch (e) {
      _startLiveFeed();
    }
  }

  void _onDetectionCompleted({XFile? imgToReturn}) {
    final String? imgPath = imgToReturn?.path;
    if (widget.isEnableSnackBar) {
      final snackBar = SnackBar(
        content: Text(imgToReturn == null
            ? 'Verification of liveness detection failed, please try again. (Exceeds time limit 45 second.)'
            : 'Verification of liveness detection success!'),
      );
      ScaffoldMessenger.of(context).showSnackBar(snackBar);
    }
    Navigator.of(context).pop(imgPath);
  }

  void _resetSteps() {
    for (var step in stepLiveness) {
      final index = stepLiveness.indexWhere((p1) => p1.step == step.step);
      stepLiveness[index] = stepLiveness[index].copyWith();
    }
    _didCloseEyes = false;
    if (_stepsKey.currentState?.currentIndex != 0) {
      _stepsKey.currentState?.reset();
    }
    if (mounted) setState(() {});
  }

  void _startProcessing() {
    if (!mounted) return;
    setState(() => _isProcessingStep = true);
  }

  void _stopProcessing() {
    if (!mounted) return;
    setState(() => _isProcessingStep = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    return Stack(
      children: [
        _isInfoStepCompleted
            ? _buildDetectionBody()
            : LivenessDetectionTutorialScreen(
                onStartTap: () {
                  if (mounted) setState(() => _isInfoStepCompleted = true);
                  _startLiveFeed();
                },
              ),
      ],
    );
  }

  Widget _buildDetectionBody() {
    if (_cameraController == null ||
        _cameraController?.value.isInitialized == false) {
      return const Center(child: CircularProgressIndicator.adaptive());
    }

    final size = MediaQuery.of(context).size;
    var scale = size.aspectRatio * _cameraController!.value.aspectRatio;
    if (scale < 1) scale = 1 / scale;

    return Stack(
      children: [
        Container(
          height: MediaQuery.of(context).size.height,
          width: MediaQuery.of(context).size.width,
          color: Colors.black,
        ),
        LivenessDetectionStepOverlayWidget(
          isFaceDetected: _faceDetectedState,
          camera: CameraPreview(_cameraController!),
          key: _stepsKey,
          steps: stepLiveness,
          onCompleted: () => Future.delayed(
            const Duration(milliseconds: 500),
            () => _takePicture(),
          ),
        ),
      ],
    );
  }

  Future<void> _handlingBlinkStep({
    required Face face,
  }) async {
    final blinkThreshold = FlutterLivenessDetectionRandomizedPlugin
            .instance.thresholdConfig
            .firstWhereOrNull((p0) => p0 is LivenessThresholdBlink)
        as LivenessThresholdBlink?;

    if ((face.leftEyeOpenProbability ?? 1.0) <
            (blinkThreshold?.leftEyeProbability ?? 0.25) &&
        (face.rightEyeOpenProbability ?? 1.0) <
            (blinkThreshold?.rightEyeProbability ?? 0.25)) {
      _startProcessing();
      if (mounted) setState(() => _didCloseEyes = true);
    }
  }

  Future<void> _handlingTurnRight({
    required Face face,
    required LivenessDetectionStep step,
  }) async {
    final headTurnThreshold = FlutterLivenessDetectionRandomizedPlugin
            .instance.thresholdConfig
            .firstWhereOrNull((p0) => p0 is LivenessThresholdHead)
        as LivenessThresholdHead?;
    if ((face.headEulerAngleY ?? 0) <
        (headTurnThreshold?.rotationAngle ?? -30)) {
      _startProcessing();
      await _completeStep(step: step);
    }
  }

  Future<void> _handlingTurnLeft({
    required Face face,
    required LivenessDetectionStep step,
  }) async {
    final headTurnThreshold = FlutterLivenessDetectionRandomizedPlugin
            .instance.thresholdConfig
            .firstWhereOrNull((p0) => p0 is LivenessThresholdHead)
        as LivenessThresholdHead?;
    if ((face.headEulerAngleY ?? 0) >
        (headTurnThreshold?.rotationAngle ?? 30)) {
      _startProcessing();
      await _completeStep(step: step);
    }
  }

  Future<void> _handlingLookUp({
    required Face face,
    required LivenessDetectionStep step,
  }) async {
    final headTurnThreshold = FlutterLivenessDetectionRandomizedPlugin
            .instance.thresholdConfig
            .firstWhereOrNull((p0) => p0 is LivenessThresholdHead)
        as LivenessThresholdHead?;
    if ((face.headEulerAngleX ?? 0) >
        (headTurnThreshold?.rotationAngle ?? 20)) {
      _startProcessing();
      await _completeStep(step: step);
    }
  }

  Future<void> _handlingLookDown({
    required Face face,
    required LivenessDetectionStep step,
  }) async {
    final headTurnThreshold = FlutterLivenessDetectionRandomizedPlugin
            .instance.thresholdConfig
            .firstWhereOrNull((p0) => p0 is LivenessThresholdHead)
        as LivenessThresholdHead?;
    if ((face.headEulerAngleX ?? 0) <
        (headTurnThreshold?.rotationAngle ?? -20)) {
      _startProcessing();
      await _completeStep(step: step);
    }
  }

  Future<void> _handlingSmile({
    required Face face,
    required LivenessDetectionStep step,
  }) async {
    final smileThreshold = FlutterLivenessDetectionRandomizedPlugin
            .instance.thresholdConfig
            .firstWhereOrNull((p0) => p0 is LivenessThresholdSmile)
        as LivenessThresholdSmile?;

    if ((face.smilingProbability ?? 0) >
        (smileThreshold?.probability ?? 0.75)) {
      _startProcessing();
      await _completeStep(step: step);
    }
  }
}