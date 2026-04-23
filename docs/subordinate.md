# Subordinate CA Infrastructure (Nested Layouts)

The `core-template` infrastructure natively supports nested deployments where a "top-level" infrastructure issues an intermediate CA certificate to a "subordinate" infrastructure. 

Once configured, the subordinate infrastructure operates **independently and offline**, issuing its own certificates for its own domain. Because the subordinate CA's certificate was signed by the top-level CA, any client that trusts the top-level Root CA will automatically trust certificates issued by the subordinate CA.

### Table of Contents
- [Example Scenario](#example-scenario)
- [Step 1: Mint the Subordinate CA on the Top-Level Host](#step-1-mint-the-subordinate-ca-on-the-top-level-host)
- [Step 2: Retrieve the Top-Level Root CA](#step-2-retrieve-the-top-level-root-ca)
- [Step 3: Transfer Files to the Subordinate Host](#step-3-transfer-files-to-the-subordinate-host)
- [Step 4: Configure the Subordinate Deployment](#step-4-configure-the-subordinate-deployment)
- [Operations and Updates](#operations-and-updates)

## Example Scenario

- **Top-Level Infrastructure (`top.internal`)**: The master deployment. Holds the Root CA.
- **Subordinate Infrastructure (`sub1.internal`)**: A nested deployment. Operates autonomously but its certificates trust back to `top.internal`.

## Step 1: Mint the Subordinate CA on the Top-Level Host

Log in to the host machine running your top-level infrastructure (`top.internal`). Use the built-in management script to mint a new intermediate CA certificate.

```bash
sudo bash core/manage.sh --mint-certs --intermediate-ca
```

**Interactive Prompts:**
1. **Common Name**: Provide a descriptive name, e.g., `sub1.internal Subordinate CA`.
2. **Validity in days**: Specify the lifetime (e.g., `3650` for 10 years).
3. **Output directory**: Enter a convenient output directory (e.g., `/tmp/sub-certs`).

This will generate two files in the output directory:
- `sub1.internal---Subordinate---CA.crt` (The intermediate CA certificate)
- `sub1.internal---Subordinate---CA.key` (The private key for the intermediate CA)

## Step 2: Retrieve the Top-Level Root CA

You will also need the Root CA certificate from the top-level infrastructure. You can download it directly from the top-level PKI web endpoint or copy it from the host.

```bash
# Download from the top-level PKI endpoint
curl -o root_ca.crt https://certificates.top.internal/root_ca.crt
```

## Step 3: Transfer Files to the Subordinate Host

Transfer the three files to the new host machine that will run the subordinate infrastructure (`sub1.internal`):
1. `root_ca.crt` (Top-level Root CA)
2. `sub1.internal---Subordinate---CA.crt` (Subordinate Intermediate CA)
3. `sub1.internal---Subordinate---CA.key` (Subordinate Private Key)

## Step 4: Configure the Subordinate Deployment

On the subordinate host, configure `custom-vars.yaml` to use the Bring-Your-Own-Certs (BYOC) mechanism. This instructs the installer to use the provided certificates instead of generating its own offline root.

```yaml
# custom-vars.yaml
domain: sub1.internal
# ... other configurations ...

# Enable BYOC and specify the paths to the transferred files
byoc: true
ca_crt_path: /path/to/transferred/root_ca.crt
ica_crt_path: /path/to/transferred/sub1.internal---Subordinate---CA.crt
ica_key_path: /path/to/transferred/sub1.internal---Subordinate---CA.key
```

Alternatively, you can provide these paths directly via command-line flags when running the installer:

```bash
sudo ./setup.sh --byoc \
    --ca-crt /path/to/transferred/root_ca.crt \
    --ica-crt /path/to/transferred/sub1.internal---Subordinate---CA.crt \
    --ica-key /path/to/transferred/sub1.internal---Subordinate---CA.key
```

## Operations and Updates

Once installed, `sub1.internal` will operate completely independently of `top.internal`. It will use Step-CA to mint its own leaf certificates, fulfill ACME challenges, and proxy traffic.

The only time it will need to interact with `top.internal` again is when the subordinate CA certificate (the intermediate CA) approaches its expiration date. At that point, you will need to repeat Step 1 to issue a renewed intermediate CA, transfer it to the subordinate host, and run a configuration update on the subordinate to apply the new certificate.
