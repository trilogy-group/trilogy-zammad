// Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

import { AutocompleteSearchObjectAttributeExternalDataSourceDocument } from '#shared/components/Form/fields/FieldExternalDataSource/graphql/queries/autocompleteSearchObjectAttributeExternalDataSource.api.ts'
import { getNodeByName } from '#shared/components/Form/utils.ts'
import type { ObjectLike } from '#shared/types/utils.ts'

import type { ExternalDataSourceProps } from './types.ts'
import type { AutocompleteSelectValue } from '../FieldAutocomplete/types.ts'
import type { FormKitNode } from '@formkit/core'
import type { JsonValue } from 'type-fest'
import type { Ref } from 'vue'

export const useFieldExternalDataSourceWrapper = (
  context: Ref<ExternalDataSourceProps['context']>,
) => {
  const additionalQueryParams = () => {
    const additionalQueryParams: Record<string, JsonValue> = {
      object: context.value.object,
      attributeName: context.value.node.name,
    }

    const { searchTemplateRenderContext, formId, object } = context.value

    const templateRenderContext: Record<string, JsonValue> = {}

    // Add the main entity object id from the current object.
    const entityObject = context.value.node.at('$root')?.context?.initialEntityObject as ObjectLike
    if (entityObject) {
      templateRenderContext[`${object.toLowerCase()}Id`] = entityObject.id
    }

    // Add additional data from the given search context information.
    if (searchTemplateRenderContext) {
      const additionaltemplateRenderContext =
        searchTemplateRenderContext(formId, entityObject) || {}

      Object.assign(templateRenderContext, additionaltemplateRenderContext)
    }

    additionalQueryParams.templateRenderContext = templateRenderContext

    return additionalQueryParams
  }

  // BU -> Product cascade (clear-on-change): when this is the product field,
  // watch the sibling Business Unit node and clear the product value when the BU
  // actually changes — otherwise an agent could save a stale BU/Product mismatch.
  // Mirrors the legacy-UI selectValue override.
  const thisNode = context.value.node as unknown as FormKitNode
  if (thisNode?.name === 'li_product') {
    const form = thisNode.at('$root') as FormKitNode | undefined
    const buNode = (form?.find?.('li_business_unit') ??
      getNodeByName(context.value.formId as string, 'li_business_unit')) as
      | FormKitNode
      | undefined

    const readBuName = (v: unknown): string => {
      if (v && typeof v === 'object') {
        const o = v as { value?: string; label?: string }
        return o.value ?? o.label ?? ''
      }
      return (v as string) ?? ''
    }

    buNode?.on('commit', ({ payload }) => {
      const currentProduct = thisNode.value
      // only clear when a product is actually set and the BU name changed
      const productSet =
        currentProduct &&
        typeof currentProduct === 'object' &&
        Object.keys(currentProduct as object).length > 0
      if (productSet && readBuName(payload) !== undefined) {
        thisNode.input({}, false)
      }
    })
  }

  return {
    actionIcon: 'search',

    gqlQuery: AutocompleteSearchObjectAttributeExternalDataSourceDocument,

    additionalQueryParams,

    complexValue: true,

    // use getter to return new value each time
    get clearValue() {
      return {}
    },

    initialOptionBuilder: (_: ObjectLike, value: AutocompleteSelectValue) => value,
  }
}
