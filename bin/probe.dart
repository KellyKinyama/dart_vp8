import 'package:dart_vp8/src/constants/coef_probs.dart';

void main() {
  final i = coefProbIndex(3, 0, 1, 0);
  print('idx=$i default=${defaultCoefProbs[i]}');
  for (int c = 0; c < 3; c++) {
    final row = <int>[];
    for (int n = 0; n < 11; n++) {
      row.add(defaultCoefProbs[coefProbIndex(3, 0, c, n)]);
    }
    print('[3][0][$c]=$row');
  }
}
