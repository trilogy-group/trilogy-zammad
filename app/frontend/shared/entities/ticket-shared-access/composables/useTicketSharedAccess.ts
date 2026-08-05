// Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

import { computed, ref } from 'vue'

import {
  NotificationTypes,
  useNotifications,
} from '#shared/components/CommonNotifications/index.ts'
import { useTicketView } from '#shared/entities/ticket/composables/useTicketView.ts'
import type { TicketById } from '#shared/entities/ticket/types.ts'
import { getIdFromGraphQLId } from '#shared/graphql/utils.ts'
import { i18n } from '#shared/i18n.ts'
import { getCSRFToken } from '#shared/server/apollo/utils/csrfToken.ts'
import { useSessionStore } from '#shared/stores/session.ts'

import type { Ref } from 'vue'

export interface SharedUser {
  id: string
  user_id: number
  ticket_id: number
  user_name?: string
  user_email?: string
  firstname?: string
  lastname?: string
  image?: string
}

interface SharedAccessApiResponse {
  shared_accesses: Array<{
    id: string
    user_id: number
    ticket_id: number
  }>
  assets: {
    User?: Record<
      number,
      {
        firstname?: string
        lastname?: string
        email?: string
        image?: string
      }
    >
  }
}

export const useTicketSharedAccess = (ticket: Ref<TicketById | undefined>) => {
  const { canShareTicket, isTicketAgent } = useTicketView(ticket)
  const session = useSessionStore()
  const { notify } = useNotifications()

  const sharedUsers = ref<SharedUser[]>([])
  const isLoadingList = ref(false)
  const isLoadingAction = ref(false)

  const canManageSharedAccess = computed(() => canShareTicket.value)

  const isLoading = computed(() => isLoadingList.value || isLoadingAction.value)

  const fetchSharedUsers = async () => {
    if (!ticket.value) return

    isLoadingList.value = true
    try {
      const response = await fetch(
        `/api/v1/ticket_shared_accesses?ticket_id=${ticket.value.internalId}`,
        {
          headers: {
            'Content-Type': 'application/json',
          },
          credentials: 'same-origin',
        },
      )

      if (!response.ok) {
        throw new Error(__('Failed to fetch shared users'))
      }

      const data: SharedAccessApiResponse = await response.json()
      const accesses = data.shared_accesses || []
      const assets = data.assets || {}

      // Process shared accesses to include user info from assets
      sharedUsers.value = accesses.map((access) => {
        const user = assets.User?.[access.user_id]
        if (user) {
          const fullname = [user.firstname, user.lastname].filter(Boolean).join(' ')
          return {
            id: access.id,
            user_id: access.user_id,
            ticket_id: access.ticket_id,
            user_name: fullname || user.email || `${__('User')} ${access.user_id}`,
            user_email: user.email,
            firstname: user.firstname,
            lastname: user.lastname,
            image: user.image,
          }
        }
        return {
          id: access.id,
          user_id: access.user_id,
          ticket_id: access.ticket_id,
        }
      })
    } catch {
      notify({
        type: NotificationTypes.Error,
        message: i18n.t('Failed to load shared users.'),
      })
      // Keep existing list on error rather than wiping it
    } finally {
      isLoadingList.value = false
    }
  }

  const shareTicket = async (userId: string) => {
    if (!ticket.value) return false

    isLoadingAction.value = true
    try {
      const response = await fetch('/api/v1/ticket_shared_accesses', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': getCSRFToken() || '',
        },
        credentials: 'same-origin',
        body: JSON.stringify({
          ticket_id: ticket.value.internalId,
          user_id: userId,
        }),
      })

      if (response.ok) {
        notify({
          type: NotificationTypes.Success,
          message: i18n.t('Ticket shared successfully!'),
        })
        await fetchSharedUsers()
        return true
      }

      // Handle error response
      const errorData = await response.json().catch(() => ({}))
      const errorMessage = errorData.error || i18n.t('Failed to share ticket.')
      notify({
        type: NotificationTypes.Error,
        message: errorMessage,
      })
      return false
    } catch {
      notify({
        type: NotificationTypes.Error,
        message: i18n.t('Failed to share ticket.'),
      })
      return false
    } finally {
      isLoadingAction.value = false
    }
  }

  const unshareTicket = async (userId: string) => {
    if (!ticket.value) return false

    isLoadingAction.value = true
    try {
      // Find the shared access ID for this user
      const sharedAccess = sharedUsers.value.find((su) => String(su.user_id) === userId)

      if (!sharedAccess) {
        notify({
          type: NotificationTypes.Error,
          message: i18n.t('Shared access not found.'),
        })
        return false
      }

      const response = await fetch(
        `/api/v1/ticket_shared_accesses/${sharedAccess.id}?ticket_id=${ticket.value.internalId}`,
        {
          method: 'DELETE',
          headers: {
            'Content-Type': 'application/json',
            'X-CSRF-Token': getCSRFToken() || '',
          },
          credentials: 'same-origin',
        },
      )

      if (response.ok) {
        notify({
          type: NotificationTypes.Success,
          message: i18n.t('Shared access removed.'),
        })
        await fetchSharedUsers()
        return true
      }

      // Handle error response
      const errorData = await response.json().catch(() => ({}))
      const errorMessage = errorData.error || i18n.t('Failed to remove shared access.')
      notify({
        type: NotificationTypes.Error,
        message: errorMessage,
      })
      return false
    } catch {
      notify({
        type: NotificationTypes.Error,
        message: i18n.t('Failed to remove shared access.'),
      })
      return false
    } finally {
      isLoadingAction.value = false
    }
  }

  const canRemoveUser = (sharedUser: SharedUser) => {
    if (!ticket.value) return false

    const currentUserId = getIdFromGraphQLId(session.userId)

    // Admins and agents with access to the ticket can remove anyone.
    if (session.hasPermission('admin') || isTicketAgent.value) return true

    // Ticket owner (submitting customer) can remove anyone.
    if (ticket.value.customer?.internalId === currentUserId) return true

    // Shared customers can only remove themselves.
    return sharedUser.user_id === currentUserId
  }

  return {
    sharedUsers,
    isLoading,
    canManageSharedAccess,
    fetchSharedUsers,
    shareTicket,
    unshareTicket,
    canRemoveUser,
  }
}
