import 'dart:io';
void main() async {
  try {
    await File('non_existent.txt').delete();
  } catch (e) {
    print(e.runtimeType);
  }
}
