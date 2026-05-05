import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:brick_build/generators.dart';
import 'package:brick_core/core.dart';
import 'package:brick_json_generators/json_deserialize.dart';
import 'package:brick_supabase/brick_supabase.dart';
import 'package:brick_supabase_generators/src/supabase_fields.dart';
import 'package:brick_supabase_generators/src/supabase_serdes_generator.dart';
import 'package:source_gen/source_gen.dart';

/// Generate a function to produce a [ClassElement] from Supabase data
class SupabaseDeserialize extends SupabaseSerdesGenerator
    with JsonDeserialize<SupabaseModel, Supabase> {
  /// Generate a function to produce a [ClassElement] from Supabase data
  SupabaseDeserialize(
    super.element,
    super.fields, {
    required super.repositoryName,
  });

  @override
  List<String> get instanceFieldsAndMethods {
    final config = (fields as SupabaseFields).config;

    return [
      if (config?.tableName != null) "@override\nfinal supabaseTableName = '${config!.tableName}';",
    ];
  }

  @override
  String deserializerNullableClause({
    required FieldElement field,
    required Supabase fieldAnnotation,
    required String name,
  }) {
    final checker = checkerForField(field);

    final selfNullableHandled = checker.isDateTime ||
        checker.isSibling ||
        checker.fromJsonConstructor != null ||
        (checker.isIterable && checkerForType(checker.argType).fromJsonConstructor != null);

    if (selfNullableHandled) return '';

    return super.deserializerNullableClause(
      field: field,
      fieldAnnotation: fieldAnnotation,
      name: name,
    );
  }

  @override
  String? coderForField(
    FieldElement field,
    SharedChecker<Model> checker, {
    required bool wrappedInFuture,
    required Supabase fieldAnnotation,
  }) {
    // Only override direct sibling associations
    if (checker.isSibling) {
      final siblingType = SharedChecker.withoutNullability(checker.unFuturedType);

      // Nested object field from Supabase payload
      final nestedFieldValue = serdesValueForField(
        field,
        fieldAnnotation.name ?? field.name!,
        checker: checker,
      );

      final foreignKey = fieldAnnotation.foreignKey;
      final isNullable = checker.isNullable;

      if (foreignKey != null) {
        final siblingElement = checker.unFuturedType.element! as ClassElement;
        final siblingFields = SupabaseFields(siblingElement);

        // Find required unique field
        final uniqueField = siblingFields.stableInstanceFields.firstWhere(
          (f) => siblingFields.annotationForField(f).unique,
          orElse: () => throw InvalidGenerationSourceError(
            'Supabase model `${siblingElement.name}` must define one non-null unique field for association resolution.',
            element: field,
          ),
        );

        // Reject nullable unique fields
        if (uniqueField.type.nullabilitySuffix != NullabilitySuffix.none) {
          throw InvalidGenerationSourceError(
            'Unique Supabase field `${uniqueField.name}` on `${siblingElement.name}` cannot be nullable.',
            element: uniqueField,
          );
        }

        // Query.where() uses Dart field names, NOT serialized column names
        final uniqueFieldName = uniqueField.name!;

        final localQuery = getAssociationMethod(
          checker.unFuturedType,
          forceNullable: isNullable,
          query: "Query.where('$uniqueFieldName', data['$foreignKey'], limit1: true)",
        );

        return '''
        $nestedFieldValue != null
            ? await ${siblingType}Adapter().fromSupabase(
                $nestedFieldValue,
                provider: provider,
                repository: repository,
              )
            : data['$foreignKey'] == null
                ? ${isNullable ? 'null' : "throw ArgumentError('Missing required association: ${field.name}')"}
                : await $localQuery
        ''';
      }
    }

    return super.coderForField(
      field,
      checker,
      wrappedInFuture: wrappedInFuture,
      fieldAnnotation: fieldAnnotation,
    );
  }
}
