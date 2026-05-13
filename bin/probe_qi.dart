import 'package:dart_vp8/src/quant.dart';

void main() {
  print(
      'dc[122]=${dcQLookup[122]} dc[120]=${dcQLookup[120]} dc[125]=${dcQLookup[125]}');
  print('ac[122]=${acQLookup[122]}');
  print('y2Dc(122,0)=${y2DcQuant(122, 0)}');
  print('y2Ac(122,0)=${y2AcQuant(122, 0)}');
  print('y1Dc(122,0)=${yDcQuant(122, 0)}');
  print('y1Ac(122)=${yAcQuant(122)}');
  print('uvDc(122,0)=${uvDcQuant(122, 0)}');
  print('uvAc(122,0)=${uvAcQuant(122, 0)}');
}
