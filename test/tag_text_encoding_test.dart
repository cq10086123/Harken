import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/source/local/tag_text_encoding.dart';

/// 中文标签乱码修复。
///
/// 这是中文曲库的实际问题：ID3v2 声明 Latin-1 但实际塞 UTF-8 字节，
/// 照声明解码会把一个汉字变成三个西欧字符。
void main() {
  group('repairMojibake', () {
    test('把被当成 Latin-1 读出来的中文还原（上游注释里的真实案例）', () {
      const original = '爱情好无奈';
      // 复现故障：UTF-8 字节按 Latin-1 解码
      final mojibake = latin1.decode(utf8.encode(original));
      expect(mojibake, isNot(original), reason: '前置条件：确实已乱码');

      expect(repairMojibake(mojibake), original);
    });

    test('正常中文原样返回（不含高位字节以外的特征时不动它）', () {
      // 已经是正确解码的中文，codeUnit 远超 0xff，第一步就返回原值
      expect(repairMojibake('周杰伦'), '周杰伦');
      expect(repairMojibake('范特西'), '范特西');
    });

    test('纯 ASCII 原样返回', () {
      expect(repairMojibake('Radiohead'), 'Radiohead');
      expect(repairMojibake('OK Computer'), 'OK Computer');
    });

    test('null 与空串原样返回', () {
      expect(repairMojibake(null), isNull);
      expect(repairMojibake(''), '');
    });

    test('英文重音符号乱码也能还原', () {
      const original = 'Café Münchén';
      final mojibake = latin1.decode(utf8.encode(original));
      expect(repairMojibake(mojibake), original);
    });

    test('混合中英文乱码还原', () {
      const original = '周杰伦 - 晴天 (Live)';
      final mojibake = latin1.decode(utf8.encode(original));
      expect(repairMojibake(mojibake), original);
    });

    test('真正的 Latin-1 文本（非乱码）不被误伤', () {
      // 0xE9 单独出现不是合法 UTF-8 起始序列，should 原样返回
      final real = latin1.decode([0x43, 0x61, 0x66, 0xE9]); // "Café" in Latin-1
      expect(real, 'Café');
      expect(repairMojibake(real), real);
    });
  });

  group('looksLikeUtf8', () {
    test('含多字节序列的合法 UTF-8 → true', () {
      expect(looksLikeUtf8(utf8.encode('爱情')), isTrue);
      expect(looksLikeUtf8(utf8.encode('Café')), isTrue);
      expect(looksLikeUtf8(utf8.encode('😀')), isTrue);
    });

    test('纯 ASCII → false（无判定价值）', () {
      expect(looksLikeUtf8(utf8.encode('hello')), isFalse);
      expect(looksLikeUtf8(<int>[]), isFalse);
    });

    test('截断的多字节序列 → false', () {
      final full = utf8.encode('爱');
      expect(looksLikeUtf8(full.sublist(0, full.length - 1)), isFalse);
    });

    test('孤立续字节（0x80-0xbf 起头）→ false', () {
      expect(looksLikeUtf8([0x80, 0x41]), isFalse);
    });

    test('过长编码（0xc0/0xc1 起头）→ false', () {
      expect(looksLikeUtf8([0xc0, 0x80]), isFalse);
      expect(looksLikeUtf8([0xc1, 0xbf]), isFalse);
    });

    test('超出 Unicode 范围（0xf5 以上）→ false', () {
      expect(looksLikeUtf8([0xf5, 0x80, 0x80, 0x80]), isFalse);
    });

    test('代理区编码 → false', () {
      // U+D800 的过长/代理编码 0xED 0xA0 0x80
      expect(looksLikeUtf8([0xed, 0xa0, 0x80]), isFalse);
    });
  });

  group('decodeTagBytes', () {
    test('声明非 Latin-1 时按 UTF-8 解', () {
      final bytes = utf8.encode('周杰伦');
      expect(decodeTagBytes(bytes, declaredLatin1: false), '周杰伦');
    });

    test('声明 Latin-1 但字节其实是 UTF-8 时，嗅探后按 UTF-8 解', () {
      final bytes = utf8.encode('周杰伦');
      expect(decodeTagBytes(bytes, declaredLatin1: true), '周杰伦');
    });

    test('声明 Latin-1 且确实是 Latin-1 时，按 Latin-1 解', () {
      // 0xE9 单独出现不构成合法多字节 UTF-8
      expect(decodeTagBytes([0x43, 0x61, 0x66, 0xE9], declaredLatin1: true), 'Café');
    });

    test('空字节返回空串', () {
      expect(decodeTagBytes(const [], declaredLatin1: true), '');
      expect(decodeTagBytes(const [], declaredLatin1: false), '');
    });

    test('畸形 UTF-8 不抛异常（allowMalformed）', () {
      expect(
        () => decodeTagBytes([0xe7, 0x88], declaredLatin1: false),
        returnsNormally,
      );
    });
  });
}
