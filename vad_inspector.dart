import 'dart:mirrors';
import 'package:vad/vad.dart';

void main() {
  ClassMirror classMirror = reflectClass(VadIterator);
  classMirror.declarations.forEach((key, value) {
    if (value is MethodMirror && !value.isPrivate) {
      print(MirrorSystem.getName(key));
    }
  });
}
