import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import 'app/app_state.dart';
import 'ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final docs = await getApplicationDocumentsDirectory();
  final state = await AppState.create(Directory('${docs.path}/stavelight'));
  runApp(ChangeNotifierProvider<AppState>.value(value: state, child: const StavelightApp()));
}
