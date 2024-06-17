import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sleep_classifier_app/sensor_data.dart';
import 'package:syncfusion_flutter_charts/charts.dart';
import 'package:tflite_flutter/tflite_flutter.dart' as tfl;
import 'package:file_picker/file_picker.dart';

import 'package:flutter_wear_os_connectivity/flutter_wear_os_connectivity.dart';

const String modelFile = 'assets/best-mo-walch-no-4018081.tflite';
const int inputWidth = 15360;
const int inputHeight = 32;
const int nEpochs = 1024;
const int nClasses = 4;

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: "",
      home: SleepClassifier(),
    );
  }
}

class SleepClassifier extends StatefulWidget {
  const SleepClassifier({super.key});

  @override
  State<SleepClassifier> createState() => _SleepClassifierState();
}

class _SleepClassifierState extends State<SleepClassifier> {
  late tfl.Interpreter _interpreter;
  List<List<double>> _csvData = [];
  static List<List<List<double>>> get _zeroModelOutput =>
      List.generate(nEpochs * nClasses, (index) => 0.0)
          .reshape<double>([1, nEpochs, nClasses]) as List<List<List<double>>>;

  static List<List<List<List<double>>>> get _zeroModelInput =>
      List.generate(inputWidth * inputHeight * 2, (index) => 0.0)
              .reshape<double>([1, inputWidth, inputHeight, 2])
          as List<List<List<List<double>>>>;

  // Initialize the output and input buffers
  final _output = _zeroModelOutput;
  final _outputBuffer = _zeroModelOutput;
  final _modelInput = _zeroModelInput;
  static const String _baseTitle = 'Sleep Wake Classifier';
  String _title = _baseTitle;

  List<String> resultCache = [];
  List<String> result = [];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        appBar: AppBar(
          title: Text(_title),
        ),
        body: Center(
            child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton(
              onPressed: deviceName != null ? _connectDevice : null,
              child: Text(deviceName != null
                  ? "${deviceName!.name}(${deviceName!.id})"
                  : "Loading ..."),
            ),
            ElevatedButton(
              onPressed: shareCsvFile,
              child: const Text("Download CSV"),
            ),
            ElevatedButton(
              onPressed: _pickCSV,
              child: const Text('Select Spectrogram CSV File'),
            ),
            const SizedBox(height: 20),
            ...resultCache.map((item) => Text(item)),
            const SizedBox(height: 20),
            ...result.map((item) => Text(item)),
            const SizedBox(height: 20),
            _csvDataHeatMap(),
            _hypnogram()
          ],
        )));
  }

  Future<void> _connectDevice() async {
    resultCache.add("Connected to ${deviceName!.name}(${deviceName!.id})");
    resultCache.add("requesting to get not synced items");

    setState(() {
      resultCache = resultCache;
    });

    _flutterWearOsConnectivity.getAllDataItems().listen((items) async {
      List<SensorData> sensorDataList = [];

      for (var item in items) {
        for (var value in item.mapData.values) {
          final sensorData = SensorData.fromJsonList(value);
          sensorDataList.addAll(sensorData);
        }

        _flutterWearOsConnectivity.deleteDataItems(uri: item.pathURI);
      }

      resultCache.add("Not Synced data: ${sensorDataList.length}");
      setState(() {
        resultCache = resultCache;
      });
      String filePath = await getFilePath();
      appendSensorDataToCsv(sensorDataList, filePath);
    });

    _flutterWearOsConnectivity.dataChanged().listen((items) async {
      List<SensorData> sensorDataList = [];

      result.clear();

      for (var each in items) {
        for (var value in each.dataItem.mapData.values) {
          final sensorData = SensorData.fromJsonList(value);
          sensorDataList.addAll(sensorData);
        }
        _flutterWearOsConnectivity.deleteDataItems(uri: each.dataItem.pathURI);
      }

      result.add("Realtime data: ${sensorDataList.length}");
      setState(() {
        result = result;
      });

      String filePath = await getFilePath();
      appendSensorDataToCsv(sensorDataList, filePath);
    });
  }

  Future<void> shareCsvFile() async {
    String filePath = await getFilePath();
    Share.shareXFiles([XFile(filePath)]);
  }

  Future<String> getFilePath() async {
    final directory = await getApplicationDocumentsDirectory();
    return '${directory.path}/sensor_data.csv';
  }

  Future<void> appendSensorDataToCsv(
      List<SensorData> sensorDataList, String filePath) async {
    final file = File(filePath);
    final sink = file.openWrite(mode: FileMode.append);

    if (!await file.exists()) {
      await file.writeAsString('ID,Value,Timestamp\n', mode: FileMode.append);
    }

    for (var sensorData in sensorDataList) {
      sink.writeln(sensorData.toCsvRow());
    }

    await sink.close();
    print('CSV file appended at $filePath');
  }

  // Function to pick a CSV file
  Future<void> _pickCSV() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv', 'out', 'txt'],
    );

    if (result != null) {
      String fileNameShort = result.files.single.name;
      String filePath = result.files.single.path!;
      _loadCSV(filePath);
      setState(() {
        _title = '$_baseTitle - $fileNameShort';
      });
    }
  }

  // Function to load CSV data
  void _loadCSV(String filePath) async {
    final csvFile = await File(filePath).readAsString();

    List<List<double>> csvData = csvFile.split('\n').map((String row) {
      try {
        return row.split(',').map(double.parse).toList();
      } catch (e) {
        return <double>[];
      }
    }).toList();

    _prepareInputData();

    setState(() {
      _csvData = csvData;
    });

    _prepareInputData();
    _predictFromCSVData();
  }

  /// Prepare input data
  /// Read CSV of shape (n, 32) and return a List of shape (n, 32, 2)
  /// where n is the number of rows in the CSV
  ///
  /// We "reflect" the 2D data to 3D by
  /// repeating the rows, reversed
  _prepareInputData() {
    setState(() {
      // copy the data into modelInput
      for (int i = 0; i < inputWidth; i++) {
        for (int j = 0; j < inputHeight; j++) {
          if (i >= _csvData.length || j >= _csvData[i].length) {
            continue;
          }
          // only one layer, always [0]
          _modelInput[0][i][j][0] = _csvData[i][j];
          // "reflect" the array across the y-axis, as in: _csvData[x][y]
          _modelInput[0][i][j][1] = _csvData[i][_csvData[i].length - j - 1];
        }
      }
    });
  }

  WearOsDevice? deviceName;
  late FlutterWearOsConnectivity _flutterWearOsConnectivity;

  @override
  void initState() {
    super.initState();
    _loadModel();

    _flutterWearOsConnectivity = FlutterWearOsConnectivity();

    _flutterWearOsConnectivity.configureWearableAPI().then((ss) {
      _flutterWearOsConnectivity.getConnectedDevices().then((devices) {
        setState(() {
          deviceName = devices.firstOrNull;
        });
      });
    });
  }

  @override
  void dispose() {
    _interpreter.close(); // Clean up when the widget is disposed
    super.dispose();
  }

  // Load the TF Lite model
  _loadModel() async {
    _interpreter = await tfl.Interpreter.fromAsset(modelFile);
    print('Model loaded successfully');
  }

  // Placeholder for making predictions (will need to update with your model input/output)
  _makePrediction(input) async {
    // Run inference
    _interpreter.run(input, _outputBuffer);

    // copy data in set state?
    setState(() {
      for (int i = 0; i < nEpochs; i++) {
        for (int j = 0; j < nClasses; j++) {
          _output[0][i][j] = _outputBuffer[0][i][j];
        }
      }
    });
  }

  _predictFromCSVData() async {
    await _makePrediction(_modelInput);
  }

  Widget _csvDataHeatMap() {
    return _csvData.isNotEmpty
        ? Row(children: [
            Expanded(
                child: HeatmapWidget(
                    // show the full model input array.
                    // Remember this has shape (1, N, 32, 2), so we do some reshaping
                    csvData: _modelInput[0]
                        .map((e) => e.map((e) => e[0]).toList())
                        .toList()))
          ])
        : const Text('No data to display');
  }

  Widget _hypnogram() {
    return _output.isNotEmpty
        ? HypnogramWidget(stageProbabilities: _output[0])
        // ? Row(children: [
        //     Expanded(child: HypnogramWidget(stageProbabilities: _output[0]))
        //   ])
        : const Text('No hypnogram to display');
  }
}

class HeatMapPainter extends CustomPainter {
  final List<List<double>> _csvData;
  bool transposed = false;

  HeatMapPainter(this._csvData, {required this.transposed});

  /// Paint the heatmap
  /// The heatmap is a grid of rectangles, where each rectangle represents a value
  /// The color of the rectangle is determined by the value
  /// The color scale can be adjusted as needed
  @override
  void paint(Canvas canvas, Size size) {
    // Define the color scale
    final absMax = _csvData.expand((row) => row).reduce(max);
    final absMin = _csvData.expand((row) => row).reduce(min);
    final colorScale = 255 / (absMax - absMin);

    // Define the size of each rectangle
    final rectWidth = size.width / inputWidth;
    final rectHeight = max(size.height / _csvData[0].length, 8.0);

    // Paint the heatmap
    for (int i = 0; i < _csvData.length; i++) {
      for (int j = 0; j < _csvData[i].length; j++) {
        final value = _csvData[i][j] - absMin;
        final color = Color.fromARGB(
          255,
          (value * colorScale).toInt(),
          (value * colorScale).toInt(),
          (value * colorScale).toInt(),
        );

        final rectLeft = (transposed ? i : j) * rectWidth;
        final rectTop = (transposed ? j : i) * rectHeight;
        final rect = Rect.fromLTWH(rectLeft, rectTop, rectWidth, rectHeight);
        final paint = Paint()..color = color;
        canvas.drawRect(rect, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

int argmax<X extends Comparable>(List<X> list) {
  return list.indexWhere((element) =>
      element == list.reduce((a, b) => a.compareTo(b) >= 0 ? a : b));
}

class HypnogramWidget extends StatelessWidget {
  late List<double> _psgData = []; // Your CSV data

  HypnogramWidget({Key? key, required List<List<double>> stageProbabilities})
      : super(key: key) {
    // take argmax to convert probabilities to maximum likelihood class
    _psgData = stageProbabilities.map((e) => argmax(e).toDouble()).toList();
  }

  @override
  Widget build(BuildContext context) {
    return SfCartesianChart(
      plotAreaBorderWidth: 0.0,
      margin: EdgeInsets.all(0.0),
      primaryXAxis: NumericAxis(isVisible: false, minimum: 0.0, maximum: 1),
      primaryYAxis: NumericAxis(
        isVisible: false,
        minimum: -1.5,
        maximum: 3.5,
      ),
      series: <CartesianSeries>[
        LineSeries(
          dataSource: _psgData
              .asMap()
              .entries
              .map((e) => ChartData(e.key, e.value))
              .toList(),
          xValueMapper: (data, _) => data.x / _psgData.length,
          yValueMapper: (data, _) => data.y,
        ),
      ],
    );
  }
}

class ChartData {
  final int x;
  final double y;

  ChartData(this.x, this.y);
}

class HeatmapWidget extends StatefulWidget {
  final List<List<double>> _csvData = []; // Your CSV data

  HeatmapWidget({super.key, required List<List<double>> csvData}) : super() {
    _csvData.addAll(csvData);
  }

  @override
  State<StatefulWidget> createState() => _HeatmapWidgetState();
}

class _HeatmapWidgetState extends State<HeatmapWidget> {
  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: HeatMapPainter(widget._csvData, transposed: true),
    );
  }
}
