import 'dart:collection';
import 'dart:convert';

import 'package:collection/src/iterable_extensions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/models/documents/nodes/block.dart';
import 'package:flutter_quill/models/documents/nodes/line.dart';
import 'package:flutter_quill/models/documents/nodes/node.dart';
import 'package:flutter_quill/models/documents/style.dart';

/// Convertor from [Delta] to quill Markdown string.
class DeltaToMarkdown extends Converter<Delta, String> {
  @override
  String convert(Delta input) {
    final quillDocument = Document.fromDelta(input);
    final visitor = _NodeVisitorImpl();

    final outBuffer = quillDocument.root.accept(visitor);

    return outBuffer.toString();
  }
}

class _AttributeHandler {
  _AttributeHandler({
    this.beforeContent,
    this.afterContent,
  });

  final void Function(
    Attribute<Object?> attribute,
    Node node,
    StringSink output,
  )? beforeContent;

  final void Function(
    Attribute<Object?> attribute,
    Node node,
    StringSink output,
  )? afterContent;
}

extension on Object? {
  T? asNullable<T>() {
    final self = this;
    return self == null ? null : self as T;
  }
}

class _NodeVisitorImpl implements _NodeVisitor<StringSink> {
  final Map<String, _AttributeHandler> _blockAttrsHandlers = {
    Attribute.codeBlock.key: _AttributeHandler(
      beforeContent: (attribute, node, output) => output.writeln('```'),
      afterContent: (attribute, node, output) => output.writeln('```'),
    ),
  };

  final Map<String, _AttributeHandler> _lineAttrsHandlers = {
    Attribute.header.key: _AttributeHandler(
      beforeContent: (attribute, node, output) {
        output
          ..write('#' * (attribute.value.asNullable<int>() ?? 1))
          ..write(' ');
      },
    ),
    Attribute.blockQuote.key: _AttributeHandler(
      beforeContent: (attribute, node, output) => output.write('> '),
    ),
    Attribute.list.key: _AttributeHandler(
      beforeContent: (attribute, node, output) {
        final indentLevel = node.getAttrValueOr(Attribute.indent.key, 0);
        final isNumbered = attribute.value == 'ordered';
        output
          ..write((isNumbered ? '   ' : '  ') * indentLevel)
          ..write('${isNumbered ? '1.' : '-'} ');
      },
    ),
  };

  final Map<String, _AttributeHandler> _textAttrsHandlers = {
    Attribute.italic.key: _AttributeHandler(
      beforeContent: (attribute, node, output) {
        if (node.previous?.containsAttr(attribute.key) != true) {
          output.write('_');
        }
      },
      afterContent: (attribute, node, output) {
        if (node.next?.containsAttr(attribute.key) != true) {
          output.write('_');
        }
      },
    ),
    Attribute.bold.key: _AttributeHandler(
      beforeContent: (attribute, node, output) {
        if (node.previous?.containsAttr(attribute.key) != true) {
          output.write('**');
        }
      },
      afterContent: (attribute, node, output) {
        if (node.next?.containsAttr(attribute.key) != true) {
          output.write('**');
        }
      },
    ),
    Attribute.strikeThrough.key: _AttributeHandler(
      beforeContent: (attribute, node, output) {
        if (node.previous?.containsAttr(attribute.key) != true) {
          output.write('~~');
        }
      },
      afterContent: (attribute, node, output) {
        if (node.next?.containsAttr(attribute.key) != true) {
          output.write('~~');
        }
      },
    ),
    Attribute.inlineCode.key: _AttributeHandler(
      beforeContent: (attribute, node, output) {
        if (node.previous?.containsAttr(attribute.key) != true) {
          output.write('`');
        }
      },
      afterContent: (attribute, node, output) {
        if (node.next?.containsAttr(attribute.key) != true) {
          output.write('`');
        }
      },
    ),
    Attribute.link.key: _AttributeHandler(
      beforeContent: (attribute, node, output) {
        if (node.previous?.containsAttr(attribute.key, attribute.value) !=
            true) {
          output.write('[');
        }
      },
      afterContent: (attribute, node, output) {
        if (node.next?.containsAttr(attribute.key, attribute.value) != true) {
          output.write('](${attribute.value.asNullable<String>() ?? ''})');
        }
      },
    ),
  };

  @override
  StringSink visitRoot(Root root, [StringSink? output]) {
    final out = output ??= StringBuffer();
    for (final container in root.children) {
      container.accept(this, out);
    }
    return out;
  }

  @override
  StringSink visitBlock(Block block, [StringSink? output]) {
    final out = output ??= StringBuffer();
    final style = block.style;
    _handleAttribute(_blockAttrsHandlers, block, output, () {
      for (final line in block.children) {
        line.accept(this, out);
      }
    });
    return out;
  }

  @override
  StringSink visitLine(Line line, [StringSink? output]) {
    final out = output ??= StringBuffer();
    final style = line.style;
    _handleAttribute(_lineAttrsHandlers, line, output, () {
      for (final leaf in line.children) {
        leaf.accept(this, out);
      }
    });
    if (style.isEmpty ||
        style.values.every((item) => item.scope != AttributeScope.BLOCK)) {
      out.writeln();
    }
    if (style.containsKey(Attribute.list.key) &&
        line.nextLine?.style.containsKey(Attribute.list.key) != true) {
      out.writeln();
    }
    out.writeln();
    return out;
  }

  @override
  StringSink visitText(Text text, [StringSink? output]) {
    final out = output ??= StringBuffer();
    final style = text.style;
    _handleAttribute(
      _textAttrsHandlers,
      text,
      output,
      () {
        out.write(
          text.value.replaceAllMapped(
              RegExp(r'[\\\`\*\_\{\}\[\]\(\)\#\+\-\.\!\>\<]'), (match) {
            return '\\${match[0]}';
          }),
        );
      },
      sortedAttrsBySpan: true,
    );
    return out;
  }

  @override
  StringSink visitEmbed(Embed embed, [StringSink? output]) {
    final out = output ??= StringBuffer();

    final type = embed.value.type;
    final dynamic data = embed.value.data;

    if (type == BlockEmbed.imageType) {
      out.write('![]($data)');
    } else if (type == BlockEmbed.horizontalRuleType) {
      // adds new line after it
      // make --- separated so it doesn't get rendered as header
      out.writeln('- - -');
    }

    return out;
  }

  void _handleAttribute(
    Map<String, _AttributeHandler> handlers,
    Node node,
    StringSink output,
    VoidCallback contentHandler, {
    bool sortedAttrsBySpan = false,
  }) {
    final attrs = sortedAttrsBySpan
        ? node.attrsSortedByLongestSpan()
        : node.style.attributes.values.toList();
    final handlersToUse = attrs
        .where((attr) => handlers.containsKey(attr.key))
        .map((attr) => MapEntry(attr.key, handlers[attr.key]!))
        .toList();
    for (final handlerEntry in handlersToUse) {
      handlerEntry.value.beforeContent?.call(
        node.style.attributes[handlerEntry.key]!,
        node,
        output,
      );
    }
    contentHandler();
    for (final handlerEntry in handlersToUse.reversed) {
      handlerEntry.value.afterContent?.call(
        node.style.attributes[handlerEntry.key]!,
        node,
        output,
      );
    }
  }
}

//// AST with visitor

@optionalTypeArgs
abstract class _NodeVisitor<T> {
  const _NodeVisitor._();

  T visitRoot(Root root, [T? context]);

  T visitBlock(Block block, [T? context]);

  T visitLine(Line line, [T? context]);

  T visitText(Text text, [T? context]);

  T visitEmbed(Embed embed, [T? context]);
}

extension _NodeX on Node {
  T accept<T>(_NodeVisitor<T> visitor, [T? context]) {
    switch (runtimeType) {
      case Root:
        return visitor.visitRoot(this as Root, context);
      case Block:
        return visitor.visitBlock(this as Block, context);
      case Line:
        return visitor.visitLine(this as Line, context);
      case Text:
        return visitor.visitText(this as Text, context);
      case Embed:
        return visitor.visitEmbed(this as Embed, context);
    }
    throw Exception('Container of type $runtimeType cannot be visited');
  }

  bool containsAttr(String attributeKey, [Object? value]) {
    if (!style.containsKey(attributeKey)) {
      return false;
    }
    if (value == null) {
      return true;
    }
    return style.attributes[attributeKey]!.value == value;
  }

  T getAttrValueOr<T>(String attributeKey, T or) {
    final attrs = style.attributes;
    final attrValue = attrs[attributeKey]?.value as T?;
    return attrValue ?? or;
  }

  List<Attribute<Object?>> attrsSortedByLongestSpan() {
    final attrCount = <Attribute, int>{};
    Node? node = this;
    // get the first node
    while (node?.previous != null) {
      node = node?.previous;
    }

    while (node != null) {
      node.style.attributes.forEach((key, value) {
        attrCount[value] = (attrCount[value] ?? 0) + 1;
      });
      node = node.next;
    }

    final attrs = style.attributes.values.sorted(
        (attr1, attr2) => attrCount[attr2]!.compareTo(attrCount[attr1]!));

    return attrs;
  }
}
