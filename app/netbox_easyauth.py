"""
Remote-user backend for Azure Container Apps authentication (Easy Auth).

Container Apps signs every request in with Entra ID and passes the user's claims in the
X-MS-CLIENT-PRINCIPAL header (base64-encoded JSON), which it sets itself on every request.
NetBox's group sync expects a plain delimited header instead, so this backend reads the
user's Entra app roles from X-MS-CLIENT-PRINCIPAL and hands them to NetBox as groups.
Any group header sent by the client is ignored.

Superuser status comes from REMOTE_AUTH_SUPERUSER_GROUPS (netbox-admins). The backend also keeps
the editor and reader groups and their permissions in NetBox in line with ROLE_PERMISSIONS, so
nothing has to be configured by hand. Both only get permissions on the apps in NETBOX_ROLE_APPS,
which keeps their navigation menu down to what is actually used. Administration (users, groups,
permissions, custom fields, scripts, data sources) stays with netbox-admins.
"""
import base64
import binascii
import json
import logging
import os

from django.db import IntegrityError

from netbox.authentication import RemoteUserBackend

logger = logging.getLogger('netbox.auth.EasyAuthRemoteUserBackend')

PRINCIPAL_HEADER = 'HTTP_X_MS_CLIENT_PRINCIPAL'
ROLE_CLAIM_TYPES = {'roles', 'http://schemas.microsoft.com/ws/2008/06/identity/claims/role'}

# NetBox apps editors and readers work in
ROLE_APPS = os.environ.get(
    'NETBOX_ROLE_APPS', 'circuits dcim ipam tenancy virtualization vpn wireless'
).split()

# Object types outside ROLE_APPS that go with documenting the network
ROLE_EXTRA_TYPES = ['extras.tag', 'extras.journalentry', 'extras.imageattachment']

# role (= NetBox group) -> (permission name, actions, extra object types as 'app_label.model')
ROLE_PERMISSIONS = {
    'netbox-editors': (
        'Editors (Entra role netbox-editors)',
        ['view', 'add', 'change', 'delete'],
        ROLE_EXTRA_TYPES,
    ),
    'netbox-readers': (
        'Readers (Entra role netbox-readers)',
        ['view'],
        ROLE_EXTRA_TYPES,
    ),
}

_roles_synced = False


def entra_roles(request, remote_user=None):
    raw = request.META.get(PRINCIPAL_HEADER) if request is not None else None
    if not raw:
        logger.warning(f"No {PRINCIPAL_HEADER} header for {remote_user}; treating user as having no roles")
        return []
    try:
        principal = json.loads(base64.b64decode(raw))
    except (binascii.Error, ValueError):
        logger.warning(f"Could not decode {PRINCIPAL_HEADER} for {remote_user}; treating user as having no roles")
        return []
    claims = principal.get('claims', [])
    role_types = ROLE_CLAIM_TYPES | {principal.get('role_typ')}
    roles = sorted({claim['val'] for claim in claims if claim.get('typ') in role_types and claim.get('val')})
    if roles:
        # Logged at warning level so it shows with NetBox's default logging
        logger.warning(f"Sign-in {remote_user}: Entra app roles {roles}")
    else:
        claim_types = sorted({claim.get('typ') for claim in claims})
        logger.warning(
            f"Sign-in {remote_user}: no Entra app roles in token (role_typ={principal.get('role_typ')}, "
            f"claim types: {claim_types})"
        )
    return roles


def _get_or_create(model, defaults=None, **kwargs):
    try:
        return model.objects.get_or_create(defaults=defaults, **kwargs)[0]
    except IntegrityError:
        # Another worker created it at the same time
        return model.objects.get(**kwargs)


def sync_role_permissions():
    """Create or update the role groups and their permissions (once per process)."""
    global _roles_synced
    if _roles_synced:
        return
    from core.models import ObjectType
    from users.models import Group, ObjectPermission

    app_types = list(ObjectType.objects.filter(app_label__in=ROLE_APPS))
    for group_name, (permission_name, actions, extra_types) in ROLE_PERMISSIONS.items():
        group = _get_or_create(Group, name=group_name)
        extras = [ObjectType.objects.get_by_natural_key(*label.split('.')) for label in extra_types]
        # actions is NOT NULL, so it must be set when the permission is created
        permission = _get_or_create(ObjectPermission, defaults={'actions': actions}, name=permission_name)
        permission.actions = actions
        permission.enabled = True
        permission.description = 'Managed by netbox_easyauth.py; manual changes are overwritten.'
        permission.save()
        permission.object_types.set(app_types + extras)
        permission.groups.set([group])
    _roles_synced = True
    logger.info(f"Synced permissions for {', '.join(ROLE_PERMISSIONS)} on apps {', '.join(ROLE_APPS)}")


class EasyAuthRemoteUserBackend(RemoteUserBackend):

    def authenticate(self, request, remote_user, remote_groups=None):
        try:
            sync_role_permissions()
        except Exception:
            # Never block sign-in because of this; the next process start retries
            logger.exception("Could not sync role permissions")
        return super().authenticate(request, remote_user, remote_groups=entra_roles(request, remote_user))
