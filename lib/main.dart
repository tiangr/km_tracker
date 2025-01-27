import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:csv/csv.dart';
import 'package:share_plus/share_plus.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final cameras = await availableCameras();
  final directory = await getApplicationDocumentsDirectory();
  Hive.init(directory.path);

  runApp(CameraApp(cameras: cameras));
}

class CameraApp extends StatelessWidget {
  final List<CameraDescription> cameras;

  CameraApp({required this.cameras});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Drive Tracker',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: MainScreen(cameras: cameras),
    );
  }
}

class MainScreen extends StatefulWidget {
  final List<CameraDescription> cameras;

  MainScreen({required this.cameras});

  @override
  _MainScreenState createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  String? _activeDriveType;
  double? _startKm;

  @override
  void initState() {
    super.initState();
    Hive.openBox('drives');
  }

  Future<void> _captureKm(String type) async {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => CameraScreen(
          cameras: widget.cameras,
          driveType: type,
          onKmCaptured: (double km) {
            setState(() {
              if (_startKm == null) {
                _startKm = km;
                _activeDriveType = type;
                _saveDrive(type, km, null);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Start KM recorded: $km')),
                );
              } else {
                final stopKm = km;
                final distance = stopKm - _startKm!;
                _saveDrive(type, _startKm, stopKm);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Stop KM recorded: $km\nDistance: $distance km')),
                );
                _startKm = null;
                _activeDriveType = null;
              }
            });
          },
        ),
      ),
    );
  }

  void _saveDrive(String type, double? startKm, double? stopKm) {
    final box = Hive.box('drives');
    box.add({
      'type': type,
      'startKm': startKm,
      'stopKm': stopKm,
      'distance': stopKm != null && startKm != null ? stopKm - startKm : null,
      'date': DateTime.now().toString(),
    });
  }

  void _viewAllDrives() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => DrivesListScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Drive Tracker')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton(
              onPressed: () => _captureKm('Job Drive'),
              child: Text(
                _activeDriveType == 'Job Drive' ? 'Stop Job Drive' : 'Start Job Drive',
              ),
            ),
            ElevatedButton(
              onPressed: () => _captureKm('Personal Drive'),
              child: Text(
                _activeDriveType == 'Personal Drive' ? 'Stop Personal Drive' : 'Start Personal Drive',
              ),
            ),
            SizedBox(height: 20),
            ElevatedButton(
              onPressed: _viewAllDrives,
              child: Text('View All Drives'),
            ),
          ],
        ),
      ),
    );
  }
}

class CameraScreen extends StatefulWidget {
  final List<CameraDescription> cameras;
  final String driveType;
  final Function(double km) onKmCaptured;

  CameraScreen({required this.cameras, required this.driveType, required this.onKmCaptured});

  @override
  _CameraScreenState createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _controller;
  Future<void>? _initializeControllerFuture;

  @override
  void initState() {
    super.initState();
    _controller = CameraController(
      widget.cameras[0],
      ResolutionPreset.high,
    );
    _initializeControllerFuture = _controller!.initialize();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _captureAndProcess() async {
    try {
      await _initializeControllerFuture;
      final image = await _controller!.takePicture();
      final croppedImage = await _cropImage(File(image.path));
      if (croppedImage != null) {
        final km = await _recognizeText(File(croppedImage.path));
        if (km != null) {
          widget.onKmCaptured(km);
          Navigator.pop(context);
        }
      }
    } catch (e) {
      print(e);
    }
  }

  Future<CroppedFile?> _cropImage(File imageFile) async {
    return await ImageCropper().cropImage(
      sourcePath: imageFile.path,
      aspectRatio: CropAspectRatio(ratioX: 1, ratioY: 1),
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: 'Crop Image',
          toolbarColor: Colors.blue,
          toolbarWidgetColor: Colors.white,
          hideBottomControls: true,
          lockAspectRatio: false,
        ),
        IOSUiSettings(
          title: 'Crop Image',
        ),
      ],
    );
  }

  Future<double?> _recognizeText(File imageFile) async {
    final inputImage = InputImage.fromFile(imageFile);
    final textRecognizer = TextRecognizer();
    try {
      final recognizedText = await textRecognizer.processImage(inputImage);
      final numericText = _extractDigits(recognizedText.text);
      return double.tryParse(numericText);
    } catch (e) {
      print('Error recognizing text: $e');
      return null;
    } finally {
      textRecognizer.close();
    }
  }

  String _extractDigits(String input) {
    final RegExp digitRegExp = RegExp(r'\d+');
    final matches = digitRegExp.allMatches(input);
    return matches.map((m) => m.group(0)).join();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${widget.driveType} - Capture KM')),
      body: FutureBuilder<void>(
        future: _initializeControllerFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done) {
            return Stack(
              children: [
                Positioned.fill(
                  child: CameraPreview(_controller!),
                ),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 30.0),
                    child: FloatingActionButton(
                      onPressed: _captureAndProcess,
                      child: Icon(Icons.camera_alt),
                    ),
                  ),
                ),
              ],
            );
          } else {
            return Center(child: CircularProgressIndicator());
          }
        },
      ),
    );
  }
}

class DrivesListScreen extends StatelessWidget {
  void _exportData(BuildContext context) async {
    final box = Hive.box('drives');
    final List<List<dynamic>> rows = [
      ['Type', 'Start KM', 'Stop KM', 'Distance', 'Date'],
    ];

    DateTime? selectedDate = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );

    if (selectedDate != null) {
      final filteredDrives = box.values.where((drive) {
        final driveDate = DateTime.parse(drive['date']);
        return driveDate.year == selectedDate.year && driveDate.month == selectedDate.month;
      });

      for (final drive in filteredDrives) {
        rows.add([
          drive['type'],
          drive['startKm'],
          drive['stopKm'],
          drive['distance'],
          drive['date'],
        ]);
      }

      final csvData = const ListToCsvConverter().convert(rows);
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/drives_${selectedDate.month}_${selectedDate.year}.csv');
      await file.writeAsString(csvData);

      Share.shareXFiles(
        [XFile(file.path)],
        text: 'Drive Records',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final box = Hive.box('drives');

    return Scaffold(
      appBar: AppBar(
        title: Text('All Drives'),
        actions: [
          IconButton(
            icon: Icon(Icons.download),
            onPressed: () => _exportData(context),
          ),
        ],
      ),
      body: ListView.builder(
        itemCount: box.length,
        itemBuilder: (context, index) {
          final drive = box.getAt(index) as Map;
          return ListTile(
            title: Text('${drive['type']} - ${drive['date']}'),
            subtitle: Text(
              'Start KM: ${drive['startKm']}, Stop KM: ${drive['stopKm']}, Distance: ${drive['distance']} km',
            ),
          );
        },
      ),
    );
  }
}
