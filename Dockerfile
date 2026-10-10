ARG NETBOX_IMAGE=docker.io/netboxcommunity/netbox:latest
FROM ${NETBOX_IMAGE}

# The image's own /etc/netbox/config/configuration.py builds every setting from environment
# variables (set in infra/main.bicep). Settings it defines cannot be overridden by extra files,
# so only add files to /etc/netbox/config/ for settings it doesn't cover, or for plugins.

# Maps Entra app roles (from the Container Apps sign-in header) to NetBox groups
COPY app/netbox_easyauth.py /opt/netbox/netbox/netbox_easyauth.py
