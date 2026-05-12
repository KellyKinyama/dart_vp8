// VP8 motion-vector and intra-mode probability defaults.
//
// Sources:
//   * vp8/common/entropymv.c  -> [defaultMvContext], [mvUpdateProbs]
//   * vp8/common/vp8_entropymodedata.h ->
//         [defaultYModeProb], [defaultUvModeProb],
//         [kfYModeProb], [kfUvModeProb], [defaultBmodeProb]
//
// MV context layout matches RFC 6386 / libvpx (MVPcount = 19):
//   [0]    is-short flag
//   [1]    sign
//   [2..8] short-magnitude tree (7 probs)
//   [9..18] long-magnitude bit probs (mvlong_width = 10)
//
// Two contexts, in order: row, column.

import 'dart:typed_data';

/// Number of probability entries per MV component context.
const int mvpCount = 19;

/// Default MV probabilities, row context then column context.
final Uint8List defaultMvContext = Uint8List.fromList(<int>[
  // row
  162, // is short
  128, // sign
  225, 146, 172, 147, 214, 39, 156, // short tree
  128, 129, 132, 75, 145, 178, 206, 239, 254, 254, // long bits
  // column
  164, // is short
  128, // sign
  204, 170, 119, 235, 140, 230, 228, // short tree
  128, 130, 130, 74, 148, 180, 203, 236, 254, 254, // long bits
]);

/// Per-frame update probabilities for the MV contexts.
final Uint8List mvUpdateProbs = Uint8List.fromList(<int>[
  // row
  237, 246,
  253, 253, 254, 254, 254, 254, 254,
  254, 254, 254, 254, 254, 250, 250, 252, 254, 254,
  // column
  231, 243,
  245, 253, 254, 254, 254, 254, 254,
  254, 254, 254, 254, 254, 251, 251, 254, 254, 254,
]);

/// Default intra-16x16 luma-mode probabilities for inter frames.
/// 4 probabilities for the tree over {DC, V, H, TM, B}.
final Uint8List defaultYModeProb = Uint8List.fromList(<int>[112, 86, 140, 37]);

/// Default intra-chroma-mode probabilities for inter frames.
/// 3 probabilities for the tree over {DC, V, H, TM}.
final Uint8List defaultUvModeProb = Uint8List.fromList(<int>[162, 101, 204]);

/// Key-frame luma-mode probabilities (fixed; not transmitted).
final Uint8List kfYModeProb = Uint8List.fromList(<int>[145, 156, 163, 128]);

/// Key-frame chroma-mode probabilities (fixed; not transmitted).
final Uint8List kfUvModeProb = Uint8List.fromList(<int>[142, 114, 183]);

/// Default 4x4 (B) intra-mode probabilities for inter frames.
final Uint8List defaultBmodeProb =
    Uint8List.fromList(<int>[120, 90, 79, 133, 87, 85, 80, 111, 151]);

/// Key-frame B-mode probability table, indexed as
/// `kfBmodeProb[above][left][node]` with `above`/`left` ∈ {B_DC_PRED..B_HU_PRED}
/// and `node` ∈ 0..8. Verbatim from vp8/common/vp8_entropymodedata.h.
final List<List<Uint8List>> kfBmodeProb = <List<Uint8List>>[
  // above = B_DC_PRED
  <Uint8List>[
    Uint8List.fromList(<int>[231, 120, 48, 89, 115, 113, 120, 152, 112]),
    Uint8List.fromList(<int>[152, 179, 64, 126, 170, 118, 46, 70, 95]),
    Uint8List.fromList(<int>[175, 69, 143, 80, 85, 82, 72, 155, 103]),
    Uint8List.fromList(<int>[56, 58, 10, 171, 218, 189, 17, 13, 152]),
    Uint8List.fromList(<int>[144, 71, 10, 38, 171, 213, 144, 34, 26]),
    Uint8List.fromList(<int>[114, 26, 17, 163, 44, 195, 21, 10, 173]),
    Uint8List.fromList(<int>[121, 24, 80, 195, 26, 62, 44, 64, 85]),
    Uint8List.fromList(<int>[170, 46, 55, 19, 136, 160, 33, 206, 71]),
    Uint8List.fromList(<int>[63, 20, 8, 114, 114, 208, 12, 9, 226]),
    Uint8List.fromList(<int>[81, 40, 11, 96, 182, 84, 29, 16, 36]),
  ],
  // above = B_TM_PRED
  <Uint8List>[
    Uint8List.fromList(<int>[134, 183, 89, 137, 98, 101, 106, 165, 148]),
    Uint8List.fromList(<int>[72, 187, 100, 130, 157, 111, 32, 75, 80]),
    Uint8List.fromList(<int>[66, 102, 167, 99, 74, 62, 40, 234, 128]),
    Uint8List.fromList(<int>[41, 53, 9, 178, 241, 141, 26, 8, 107]),
    Uint8List.fromList(<int>[104, 79, 12, 27, 217, 255, 87, 17, 7]),
    Uint8List.fromList(<int>[74, 43, 26, 146, 73, 166, 49, 23, 157]),
    Uint8List.fromList(<int>[65, 38, 105, 160, 51, 52, 31, 115, 128]),
    Uint8List.fromList(<int>[87, 68, 71, 44, 114, 51, 15, 186, 23]),
    Uint8List.fromList(<int>[47, 41, 14, 110, 182, 183, 21, 17, 194]),
    Uint8List.fromList(<int>[66, 45, 25, 102, 197, 189, 23, 18, 22]),
  ],
  // above = B_VE_PRED
  <Uint8List>[
    Uint8List.fromList(<int>[88, 88, 147, 150, 42, 46, 45, 196, 205]),
    Uint8List.fromList(<int>[43, 97, 183, 117, 85, 38, 35, 179, 61]),
    Uint8List.fromList(<int>[39, 53, 200, 87, 26, 21, 43, 232, 171]),
    Uint8List.fromList(<int>[56, 34, 51, 104, 114, 102, 29, 93, 77]),
    Uint8List.fromList(<int>[107, 54, 32, 26, 51, 1, 81, 43, 31]),
    Uint8List.fromList(<int>[39, 28, 85, 171, 58, 165, 90, 98, 64]),
    Uint8List.fromList(<int>[34, 22, 116, 206, 23, 34, 43, 166, 73]),
    Uint8List.fromList(<int>[68, 25, 106, 22, 64, 171, 36, 225, 114]),
    Uint8List.fromList(<int>[34, 19, 21, 102, 132, 188, 16, 76, 124]),
    Uint8List.fromList(<int>[62, 18, 78, 95, 85, 57, 50, 48, 51]),
  ],
  // above = B_HE_PRED
  <Uint8List>[
    Uint8List.fromList(<int>[193, 101, 35, 159, 215, 111, 89, 46, 111]),
    Uint8List.fromList(<int>[60, 148, 31, 172, 219, 228, 21, 18, 111]),
    Uint8List.fromList(<int>[112, 113, 77, 85, 179, 255, 38, 120, 114]),
    Uint8List.fromList(<int>[40, 42, 1, 196, 245, 209, 10, 25, 109]),
    Uint8List.fromList(<int>[100, 80, 8, 43, 154, 1, 51, 26, 71]),
    Uint8List.fromList(<int>[88, 43, 29, 140, 166, 213, 37, 43, 154]),
    Uint8List.fromList(<int>[61, 63, 30, 155, 67, 45, 68, 1, 209]),
    Uint8List.fromList(<int>[142, 78, 78, 16, 255, 128, 34, 197, 171]),
    Uint8List.fromList(<int>[41, 40, 5, 102, 211, 183, 4, 1, 221]),
    Uint8List.fromList(<int>[51, 50, 17, 168, 209, 192, 23, 25, 82]),
  ],
  // above = B_LD_PRED
  <Uint8List>[
    Uint8List.fromList(<int>[125, 98, 42, 88, 104, 85, 117, 175, 82]),
    Uint8List.fromList(<int>[95, 84, 53, 89, 128, 100, 113, 101, 45]),
    Uint8List.fromList(<int>[75, 79, 123, 47, 51, 128, 81, 171, 1]),
    Uint8List.fromList(<int>[57, 17, 5, 71, 102, 57, 53, 41, 49]),
    Uint8List.fromList(<int>[115, 21, 2, 10, 102, 255, 166, 23, 6]),
    Uint8List.fromList(<int>[38, 33, 13, 121, 57, 73, 26, 1, 85]),
    Uint8List.fromList(<int>[41, 10, 67, 138, 77, 110, 90, 47, 114]),
    Uint8List.fromList(<int>[101, 29, 16, 10, 85, 128, 101, 196, 26]),
    Uint8List.fromList(<int>[57, 18, 10, 102, 102, 213, 34, 20, 43]),
    Uint8List.fromList(<int>[117, 20, 15, 36, 163, 128, 68, 1, 26]),
  ],
  // above = B_RD_PRED
  <Uint8List>[
    Uint8List.fromList(<int>[138, 31, 36, 171, 27, 166, 38, 44, 229]),
    Uint8List.fromList(<int>[67, 87, 58, 169, 82, 115, 26, 59, 179]),
    Uint8List.fromList(<int>[63, 59, 90, 180, 59, 166, 93, 73, 154]),
    Uint8List.fromList(<int>[40, 40, 21, 116, 143, 209, 34, 39, 175]),
    Uint8List.fromList(<int>[57, 46, 22, 24, 128, 1, 54, 17, 37]),
    Uint8List.fromList(<int>[47, 15, 16, 183, 34, 223, 49, 45, 183]),
    Uint8List.fromList(<int>[46, 17, 33, 183, 6, 98, 15, 32, 183]),
    Uint8List.fromList(<int>[65, 32, 73, 115, 28, 128, 23, 128, 205]),
    Uint8List.fromList(<int>[40, 3, 9, 115, 51, 192, 18, 6, 223]),
    Uint8List.fromList(<int>[87, 37, 9, 115, 59, 77, 64, 21, 47]),
  ],
  // above = B_VR_PRED
  <Uint8List>[
    Uint8List.fromList(<int>[104, 55, 44, 218, 9, 54, 53, 130, 226]),
    Uint8List.fromList(<int>[64, 90, 70, 205, 40, 41, 23, 26, 57]),
    Uint8List.fromList(<int>[54, 57, 112, 184, 5, 41, 38, 166, 213]),
    Uint8List.fromList(<int>[30, 34, 26, 133, 152, 116, 10, 32, 134]),
    Uint8List.fromList(<int>[75, 32, 12, 51, 192, 255, 160, 43, 51]),
    Uint8List.fromList(<int>[39, 19, 53, 221, 26, 114, 32, 73, 255]),
    Uint8List.fromList(<int>[31, 9, 65, 234, 2, 15, 1, 118, 73]),
    Uint8List.fromList(<int>[88, 31, 35, 67, 102, 85, 55, 186, 85]),
    Uint8List.fromList(<int>[56, 21, 23, 111, 59, 205, 45, 37, 192]),
    Uint8List.fromList(<int>[55, 38, 70, 124, 73, 102, 1, 34, 98]),
  ],
  // above = B_VL_PRED
  <Uint8List>[
    Uint8List.fromList(<int>[102, 61, 71, 37, 34, 53, 31, 243, 192]),
    Uint8List.fromList(<int>[69, 60, 71, 38, 73, 119, 28, 222, 37]),
    Uint8List.fromList(<int>[68, 45, 128, 34, 1, 47, 11, 245, 171]),
    Uint8List.fromList(<int>[62, 17, 19, 70, 146, 85, 55, 62, 70]),
    Uint8List.fromList(<int>[75, 15, 9, 9, 64, 255, 184, 119, 16]),
    Uint8List.fromList(<int>[37, 43, 37, 154, 100, 163, 85, 160, 1]),
    Uint8List.fromList(<int>[63, 9, 92, 136, 28, 64, 32, 201, 85]),
    Uint8List.fromList(<int>[86, 6, 28, 5, 64, 255, 25, 248, 1]),
    Uint8List.fromList(<int>[56, 8, 17, 132, 137, 255, 55, 116, 128]),
    Uint8List.fromList(<int>[58, 15, 20, 82, 135, 57, 26, 121, 40]),
  ],
  // above = B_HD_PRED
  <Uint8List>[
    Uint8List.fromList(<int>[164, 50, 31, 137, 154, 133, 25, 35, 218]),
    Uint8List.fromList(<int>[51, 103, 44, 131, 131, 123, 31, 6, 158]),
    Uint8List.fromList(<int>[86, 40, 64, 135, 148, 224, 45, 183, 128]),
    Uint8List.fromList(<int>[22, 26, 17, 131, 240, 154, 14, 1, 209]),
    Uint8List.fromList(<int>[83, 12, 13, 54, 192, 255, 68, 47, 28]),
    Uint8List.fromList(<int>[45, 16, 21, 91, 64, 222, 7, 1, 197]),
    Uint8List.fromList(<int>[56, 21, 39, 155, 60, 138, 23, 102, 213]),
    Uint8List.fromList(<int>[85, 26, 85, 85, 128, 128, 32, 146, 171]),
    Uint8List.fromList(<int>[18, 11, 7, 63, 144, 171, 4, 4, 246]),
    Uint8List.fromList(<int>[35, 27, 10, 146, 174, 171, 12, 26, 128]),
  ],
  // above = B_HU_PRED
  <Uint8List>[
    Uint8List.fromList(<int>[190, 80, 35, 99, 180, 80, 126, 54, 45]),
    Uint8List.fromList(<int>[85, 126, 47, 87, 176, 51, 41, 20, 32]),
    Uint8List.fromList(<int>[101, 75, 128, 139, 118, 146, 116, 128, 85]),
    Uint8List.fromList(<int>[56, 41, 15, 176, 236, 85, 37, 9, 62]),
    Uint8List.fromList(<int>[146, 36, 19, 30, 171, 255, 97, 27, 20]),
    Uint8List.fromList(<int>[71, 30, 17, 119, 118, 255, 17, 18, 138]),
    Uint8List.fromList(<int>[101, 38, 60, 138, 55, 70, 43, 26, 142]),
    Uint8List.fromList(<int>[138, 45, 61, 62, 219, 1, 81, 188, 64]),
    Uint8List.fromList(<int>[32, 41, 20, 117, 151, 142, 20, 21, 163]),
    Uint8List.fromList(<int>[112, 19, 12, 61, 195, 128, 48, 4, 24]),
  ],
];
