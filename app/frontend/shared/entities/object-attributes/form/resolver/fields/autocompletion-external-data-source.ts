// Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

import { getNodeByName } from '#shared/components/Form/utils.ts'
import type { FieldResolverModule } from '#shared/entities/object-attributes/types/resolver.ts'
import { EnumObjectManagerObjects } from '#shared/graphql/types.ts'
import { ensureGraphqlId } from '#shared/graphql/utils.ts'
import type { ObjectLike } from '#shared/types/utils.ts'

import { FieldResolver } from '../FieldResolver.ts'

import type { JsonValue } from 'type-fest'

export class FieldResolverAutocompletionExternalDataSource extends FieldResolver {
  fieldType = 'externalDataSource'

  public fieldTypeAttributes() {
    return {
      props: {
        clearable: !!this.attributeConfig.nulloption,
        noOptionsLabelTranslation: !this.attributeConfig.translate,
        object: this.object,
        searchTemplateRenderContext: (formId: string, entityObject: ObjectLike) => {
          const templateRenderContext: Record<string, JsonValue> = {}

          switch (this.object) {
            case EnumObjectManagerObjects.Ticket: {
              if (entityObject) {
                templateRenderContext.customerId = entityObject.customer?.id
              }

              if (!templateRenderContext.customerId) {
                const node = getNodeByName(formId, 'customer_id')
                const value = node?.value as string

                if (value) {
                  templateRenderContext.customerId = ensureGraphqlId('User', value)
                }
              }

              // BU -> Product cascade: forward the LIVE (possibly unsaved) Business
              // Unit so the product lookup's #{ticket.li_business_unit} reflects the
              // agent's current pick, not the saved ticket value. The BU field stores
              // a {value,label} object (complexValue); read its name.
              if (this.attributeConfig.name === 'li_product') {
                const buNode = getNodeByName(formId, 'li_business_unit')
                const buValue = buNode?.value
                const buName =
                  buValue && typeof buValue === 'object'
                    ? ((buValue as { value?: string; label?: string }).value ??
                      (buValue as { label?: string }).label)
                    : (buValue as string | undefined)

                if (buName) templateRenderContext.liBusinessUnitLive = buName
              }

              return templateRenderContext
            }
            case EnumObjectManagerObjects.User:
            case EnumObjectManagerObjects.Organization:
            case EnumObjectManagerObjects.Group:
            default:
              return templateRenderContext
          }
        },
      },
    }
  }
}

export default <FieldResolverModule>{
  type: 'autocompletion_ajax_external_data_source',
  resolver: FieldResolverAutocompletionExternalDataSource,
}
