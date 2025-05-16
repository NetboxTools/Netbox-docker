# Netbox Community Docker image
Can be found at;

## Configuration.py - Netbox config

### Allowed_hosts
Update "Allowed_hosts" with all the fqdns that your netbox image can be reached at.
For example;
```
ALLOWED_HOSTS = [
    'netbox.contoso.com',
    'container.containerappenv.region.azurecontainerapps.io'
]
```

### DATABASE
PostgreSQL database configuration. See the Django documentation for a complete list of available parameters:
https://docs.djangoproject.com/en/stable/ref/settings/#databases
Update name, user, password and host to your database backend, example below shows an Azure postgres flexible server backend.
```
DATABASE = {
    'ENGINE': 'django.db.backends.postgresql',  # Database engine
    'NAME': 'netboxdb',         # Database name
    'USER': 'netboxadmin',               # PostgreSQL username
    'PASSWORD': 'netboxadminpassword',      # PostgreSQL password
    'HOST': 'mydatabase.postgres.database.azure.com',      # Database server
    'PORT': '5432',               # Database port (leave blank for default)
    'CONN_MAX_AGE': 300,      # Max database connection age
}
```

### Redis
Redis database settings. Redis is used for caching and for queuing background tasks such as webhook events. A separate
configuration exists for each. Full connection details are required in both sections, and it is strongly recommended
to use two separate database IDs.
Update the tasks.host & caching.host to your hostname, username, password and database.
```
REDIS = {
    'tasks': {
        'HOST': 'myredis',
        'PORT': 6379,
        # Comment out `HOST` and `PORT` lines and uncomment the following if using Redis Sentinel
        # 'SENTINELS': [('mysentinel.redis.example.com', 6379)],
        # 'SENTINEL_SERVICE': 'netbox',
        'USERNAME': 'default',
        'PASSWORD': 'mypassword',
        'DATABASE': 0,
        'SSL': False,
        # Set this to True to skip TLS certificate verification
        # This can expose the connection to attacks, be careful
        # 'INSECURE_SKIP_TLS_VERIFY': False,
        # Set a path to a certificate authority, typically used with a self signed certificate.
        # 'CA_CERT_PATH': '/etc/ssl/certs/ca.crt',
    },
    'caching': {
        'HOST': 'myredis',
        'PORT': 6379,
        # Comment out `HOST` and `PORT` lines and uncomment the following if using Redis Sentinel
        # 'SENTINELS': [('mysentinel.redis.example.com', 6379)],
        # 'SENTINEL_SERVICE': 'netbox',
        'USERNAME': 'default',
        'PASSWORD': 'mypassword',
        'DATABASE': 1,
        'SSL': False,
        # Set this to True to skip TLS certificate verification
        # This can expose the connection to attacks, be careful
        # 'INSECURE_SKIP_TLS_VERIFY': False,
        # Set a path to a certificate authority, typically used with a self signed certificate.
        # 'CA_CERT_PATH': '/etc/ssl/certs/ca.crt',
    }
}
```

### Secret_key
This key is used for secure generation of random numbers and strings. It must never be exposed outside of this file.
For optimal security, SECRET_KEY should be at least 50 characters in length and contain a mix of letters, numbers, and
symbols. NetBox will not run without this defined. For more information, see
https://docs.djangoproject.com/en/stable/ref/settings/#std:setting-SECRET_KEY
SECRET_KEY = 'REDACTED'

### Optional configuration
#### EXEMPT_VIEW_PERMISSIONS

Exempt certain models from the enforcement of view permissions. Models listed here will be viewable by all users and
by anonymous users. List models in the form `<app>.<model>`. Add '*' to this list to exempt all models.
Can be found at https://github.com/netbox-community/netbox/blob/develop/docs/models/
```
EXEMPT_VIEW_PERMISSIONS = [
    'dcim.site',
    'dcim.device',
    'dcim.interface',
    'dcim.rack',
    'virtualization.virtualmachine',
    'virtualization.vminterface',
    'virtualization.virtualdisk',
    'ipam.ipaddress',
    'ipam.prefix'
]
```

#### Remote Authentication Support (Entra Id)
Remote authentication support
```
REMOTE_AUTH_ENABLED = False
REMOTE_AUTH_BACKEND = 'social_core.backends.azuread.AzureADOAuth2'
SOCIAL_AUTH_AZUREAD_OAUTH2_KEY = '00000000-0000-0000-0000-000000000000'
SOCIAL_AUTH_AZUREAD_OAUTH2_SECRET = 'REDACTED'
```

#### Branding / Banners
BANNER_LOGIN = 'Contoso Production Netbox Environment, For any access questions please reach out to Contoso IT department.'
BANNER_TOP = 'Contoso Production Netbox Environment'

## Redis.conf
Update the row with your key (replace mysecret with your value)
```
user netbox on +@admin +@connection allkeys >mysecret
```