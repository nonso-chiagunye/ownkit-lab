# Install Rocky Linux, Apache in Reverse Proxy Mode, ModSecurity and OWASP Core Ruleset on LAN2

## Download and Install Rocky Linux
- Click [here](LAN1-DC-IIS/README.md) on steps to create internal v-Switch and configure on pfSense (Name the switch LAN2, assign IP 10.10.1.0/24)
- Visit [here](https://rockylinux.org/download) to download Rocky Linux 9.6 
- Open Hyper-V Manager. Right-side under "Actions", New > Virtual Machine > Next
- Under Name, give a name (like modsec) > Generation 1 > Startup memory (4096 MB can do) > Under Connection, ensure you select LAN2 you created earlier > HDD location, you can leave default > Install an OS from a bootable CD/DVD (browse to where you downloaded the Rocky Linux .iso) > Review and Finish
- Right-click the VM (modsec) > Connect > Start (Follow the Onscreen instruction to install the server)

## Setup Network Details on Rocky Linux
- The system will load with an automatically assigned IP from address pool in your DHCP settings of pfSense. Modify this to your desired configuration based on the architecture.
```bash
# Confirm the interface name
nmcli con show   # This can be eth0 or any other assigned interface name

# Change IP address
sudo nmcli con mod "<interface_name>" ipv4.addresses 10.10.1.10/24

# Assign gateway
sudo nmcli con mod "<interface_name>" ipv4.gateway 10.10.1.1

# Make the network config manual, so DHCP will not overwrite it
sudo nmcli con mod "<interface_name>" ipv4.method manual

# Change the DNS to ownkit.com DNS, so it can resolve hosts locally
sudo nmcli con mod "<interface_name>" ipv4.dns "192.168.1.10 8.8.8.8"

# Restart network connection
sudo nmcli con down "<interface_name>" && sudo nmcli con up "<interface_name>"
```

## Install and Configure ModSecurity
- There are 2 ways you can install ModSecurity. Either you build from source, or you install prebuilt version
- This setup uses a prebuilt version of ModSecurity

**Update system and install prerequisites**
```bash
sudo dnf update -y
sudo dnf install epel-release openssl -y
```

**Install Apache, ModSecurity and Dependencies**
```bash
sudo dnf install httpd mod_ssl mod_security git wget -y
```

**Download and Setup OWASP Core Ruleset**
- The Core Ruleset comes with basic configuration in modsecurity.conf.example. This should be renamed to modsecurity.conf, and serve as the building block of crs configuration.

```bash
sudo git clone https://github.com/coreruleset/coreruleset /etc/httpd/modsecurity-crs
cd /etc/httpd/modsecurity-crs
sudo cp crs-setup.conf.example crs-setup.conf
```

**Configure ModSecurity**
- During setup and testing, you can set SecRuleEngine to DetectionOnly. Change to On when everything works fine.
- Edit mod_security.conf and ensure both both crs-setup.conf and rules directory (both from core ruleset) are included. At the end, it should look like this;

```bash
sudo nano /etc/httpd/conf.d/mod_security.conf
```

```conf
<IfModule mod_security2.c>
    # Default recommended configuration
    SecRuleEngine On
#    SecRuleEngine DetectionOnly
    SecRequestBodyAccess On
    SecRule REQUEST_HEADERS:Content-Type "text/xml" \
         "id:'200000',phase:1,t:none,t:lowercase,pass,nolog,ctl:requestBodyProcessor=XML"
    SecRequestBodyLimit 13107200
    SecRequestBodyNoFilesLimit 131072
    SecRequestBodyInMemoryLimit 131072
    SecRequestBodyLimitAction Reject
    SecRule REQBODY_ERROR "!@eq 0" \
    "id:'200001', phase:2,t:none,log,deny,status:400,msg:'Failed to parse request body.',logdata:'%{reqbody_error_msg}',severity:2"
    SecRule MULTIPART_STRICT_ERROR "!@eq 0" \
    "id:'200002',phase:2,t:none,log,deny,status:400,msg:'Multipart request body \
    failed strict validation: \
    PE %{REQBODY_PROCESSOR_ERROR}, \
    BQ %{MULTIPART_BOUNDARY_QUOTED}, \
    BW %{MULTIPART_BOUNDARY_WHITESPACE}, \
    DB %{MULTIPART_DATA_BEFORE}, \
    DA %{MULTIPART_DATA_AFTER}, \
    HF %{MULTIPART_HEADER_FOLDING}, \
    LF %{MULTIPART_LF_LINE}, \
    SM %{MULTIPART_MISSING_SEMICOLON}, \
    IQ %{MULTIPART_INVALID_QUOTING}, \
    IP %{MULTIPART_INVALID_PART}, \
    IH %{MULTIPART_INVALID_HEADER_FOLDING}, \
    FL %{MULTIPART_FILE_LIMIT_EXCEEDED}'"

    SecRule MULTIPART_UNMATCHED_BOUNDARY "!@eq 0" \
    "id:'200003',phase:2,t:none,log,deny,status:44,msg:'Multipart parser detected a possible unmatched boundary.'"

    SecPcreMatchLimit 1000
    SecPcreMatchLimitRecursion 1000

    SecRule TX:/^MSC_/ "!@streq 0" \
            "id:'200004',phase:2,t:none,deny,msg:'ModSecurity internal error flagged: %{MATCHED_VAR_NAME}'"

    SecResponseBodyAccess Off
    # Ensure below file exisist. If not, create it
    SecDebugLog /var/log/httpd/modsec_debug.log
    SecDebugLogLevel 9
    SecAuditEngine RelevantOnly
    SecAuditLogRelevantStatus "^(?:5|4(?!04))"
    SecAuditLogParts ABIJDEFHZ
    SecAuditLogType Serial
    # Ensure below file exixts. If not, create it
    SecAuditLog /var/log/httpd/modsec_audit.log
    SecArgumentSeparator &
    SecCookieFormat 0
    SecTmpDir /var/lib/mod_security
    SecDataDir /var/lib/mod_security

    # ModSecurity Core Rules Set and Local configuration
	IncludeOptional modsecurity.d/*.conf
	IncludeOptional modsecurity.d/activated_rules/*.conf
	IncludeOptional modsecurity.d/local_rules/*.conf
#   CRS main configuration
    Include /etc/httpd/modsecurity-crs/crs-setup.conf

    SecAction "id:900000,phase:1,pass,nolog,\
         setvar:tx.paranoia_level=1"
#   Contains different CRS rules
    Include /etc/httpd/modsecurity-crs/rules/*.conf
    
</IfModule>
```

**Obtain and Install Certificates from DC01**
- Generate Private Key and CSR on Rocky Server
```bash
# Create a directory for certs
sudo mkdir -p /etc/pki/tls/private
sudo mkdir -p /etc/pki/tls/certs
```

- Generate a 2048-bit private key and CSR
```bash
sudo openssl genrsa -out /etc/pki/tls/private/ownkit.key 2048
sudo openssl req -new -key /etc/pki/tls/private/ownkit.key -out /etc/pki/tls/certs/ownkit.csr \
    -subj "/C=AE/ST=Dubai/L=Dubai/O=ownkit/CN=www.ownkit.com" \
    -addext "subjectAltName = DNS:www.ownkit.com, DNS:webapp.ownkit.com"
# Adjust subject details (C=Country, ST=State, etc.)
sudo cat /etc/pki/tls/certs/ownkit.csr
# Copy the conent
```

**Submit CSR to CA via Web Enrollment**
- From web browser, go to https://192.168.1.10/certsrv (the CA, DC01)
- Select "Request a certificate" > "Advanced certificate request"
- Paste the contents of /etc/pki/tls/certs/ownkit.csr (base64-encoded CSR)
- Under certificate template, choose "Web Server"
- Submit the request
- Download the certificate in Base-64 encoded format (CER file)
- Convert the .cer to .crt and send to the cert folder
```bash
sudo cp ~/Downloads/ownkit.cer /etc/pki/tls/certs/ownkit.crt
```

**Export CA Certificate and Install Trust on Apache**
- On the CA server (192.168.1.10), Open certmgr.msc > Trusted Root Certification Authorities > Certificates > Right-click ownkit-DC01-CA > All Tasks > Export > Base-64 encoded X.509 (.CER)
- Save as ca.crt
- Copy ca.crt to the Rocky server at /etc/pki/tls/certs/ca.crt

**Grant Apache proper permissions to the key and certificate files**
```bash
sudo chmod 644 /etc/pki/tls/certs/ownkit.crt /etc/pki/tls/certs/ca.crt
sudo chmod 600 /etc/pki/tls/private/ownkit.key
sudo chown apache:apache /etc/pki/tls/private/ownkit.key
```

**Create custom files for Logging**
```bash
sudo touch /var/log/httpd/ownkit_error.log  # For error logs
sudo touch /var/log/httpd/ownkit_access.log  # For access logs
```

**Create a custom error message to be served by ModSecurity for rejected/failed request**
```bash
# Create the file below
sudo nano /var/www/html/errors/403.html
```

```html
<!--Paste the below content-->
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Access Denied</title>
</head>
<body>
    <h1>Access Denied</h1>
    <p>Your request has been blocked due to security reasons. Please try again or contact support if this is an error.</p>
</body>
</html>
```

**Configure Apache as Reverse Proxy with HTTP Redirect**
- Create a config file for ownkit.com site
```bash
sudo nano /etc/httpd/conf.d/ownkit.conf
```
- Add the below content
```conf
# Ensure Apache listens on port 443
Listen 443 https
# Global configuration
ServerTokens Prod
ServerSignature Off

# HTTP VirtualHost for www.ownkit.com
<VirtualHost *:80>
    ServerName www.ownkit.com
    Redirect permanent / https://www.ownkit.com/
    ErrorDocument 403 /errors/403.html
</VirtualHost>

# HTTP VirtualHost for webapp.ownkit.com
<VirtualHost *:80>
    ServerName webapp.ownkit.com
    Redirect permanent / https://webapp.ownkit.com/
    ErrorDocument 403 /errors/403.html
</VirtualHost>

# SSL Session Cache
<IfModule mod_ssl.c>
    SSLSessionCache shmcb:/run/httpd/sslcache(512000)
    SSLSessionCacheTimeout 300
</IfModule>

# HTTPS VirtualHost with proxy
<IfModule mod_ssl.c>
Alias /errors /var/www/html/errors
<Directory /var/www/html/errors>
    Options None
    AllowOverride None
    Require all granted
</Directory>

<VirtualHost *:443>
    ServerName www.ownkit.com
    ServerAlias webapp.ownkit.com
    SSLEngine On
    SSLCertificateFile /etc/pki/tls/certs/ownkit.crt
    SSLCertificateKeyFile /etc/pki/tls/private/ownkit.key
    SSLProxyEngine On
    SSLProxyVerify require
    SSLProxyCACertificateFile /etc/pki/tls/certs/ca.crt
    SSLProtocol all -SSLv2 -SSLv3 -TLSv1 -TLSv1.1
    SSLCipherSuite ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305
    SSLHonorCipherOrder On
    SecRuleEngine On
    ProxyPreserveHost On
    # Exclude /errors from proxying
    ProxyPass /errors !
    ProxyPass / https://192.168.1.11/
    ProxyPassReverse / https://192.168.1.11/
    ErrorDocument 403 /errors/403.html
    SetEnvIf User-Agent "^curl/" is_curl=1
    Header always set X-Proxied-Through "ModSecurity" env=is_curl
    # Suppress backend Server header
    Header unset Server
    Header always set Server "Apache"
    ErrorLog /var/log/httpd/ownkit_error.log
    CustomLog /var/log/httpd/ownkit_access.log combined
</VirtualHost>

</IfModule>
```

**Backup and Disable the Default SSL Config to force Apache use your certificates**
```bash
sudo cp /etc/httpd/conf.d/ssl.conf /etc/httpd/conf.d/ssl.conf.bak
sudo mv /etc/httpd/conf.d/ssl.conf /etc/httpd/conf.d/ssl.conf.disabled
```

**Test the configuration**
```bash
sudo apachectl configtest
```

**Configure Firewall and Start Apache**
- Allow HTTP and HTTPS
```bash
sudo firewall-cmd --permanent --add-service=http --add-service=https
sudo firewall-cmd --reload
```
- Start and enable Apache
```bash
sudo systemctl start httpd
sudo systemctl enable httpd
sudo systemctl status httpd
```

**Test the setup**
```bash
curl http://www.ownkit.com  # Should redirect to https://www.ownkit.com
curl https://www.ownkit.com # Should fetch the web page
# Tail the log
sudo tail -f /var/log/httpd/modsec_audit.log
# Then try to simulate an SQLi attack
curl https://www.ownkit.com?test=union+select # You should see threshold matched alert, but still fetched page
```

- If everything works as desired, edit /etc/httpd/conf.d/mod_security.conf to change SecRuleEngine DetectionOnly to On
- Restart Apache
```bash
sudo systemctl restart httpd
```


```python

```
