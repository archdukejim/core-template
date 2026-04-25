# Subordinate CA Infrastructure (Nested Layouts)

The `core-template` infrastructure natively supports multi-tier, nested PKI deployments. This allows you to build a comprehensive hierarchy where a "Top-Level" Intermediate CA (ICA) can issue both local application certificates AND sign further Subordinate ICAs for segmented environments.

Because all intermediate CAs in this chain are ultimately derived from the same Root CA, any device that trusts the Root CA will automatically trust application certificates issued by *any* ICA in the network, establishing seamless mutual trust across all levels.

### Table of Contents
- [Intended Architectural Workflow](#intended-architectural-workflow)
- [Example Scenario](#example-scenario)
- [Step 1: Mint the Subordinate CA on the Top-Level Host](#step-1-mint-the-subordinate-ca-on-the-top-level-host)
- [Step 2: Retrieve the Root CA](#step-2-retrieve-the-root-ca)
- [Step 3: Transfer Files to the Subordinate Host](#step-3-transfer-files-to-the-subordinate-host)
- [Step 4: Configure the Subordinate Deployment](#step-4-configure-the-subordinate-deployment)
- [Operations and Updates](#operations-and-updates)

## Intended Architectural Workflow

A highly secure, best-practice deployment looks like this:
1. **Offline Root CA**: A highly secured, offline machine generates the Root CA and signs the certificate for your **Top-Level ICA**. The Root CA then goes offline to protect its private key.
2. **Top-Level ICA**: Installed via BYOC (Bring Your Own Certs) on your master infrastructure. This ICA performs two roles:
   - Signs application/leaf certificates for its local network.
   - Generates and signs certificates for downstream **Second-Level ICAs**.
3. **Second-Level ICAs**: Segmented infrastructure deployments that operate independently to sign application/leaf certificates for their respective networks.

## Example Scenario

- **Top-Level Infrastructure (`top.internal`)**: Deployed using BYOC with the Top-Level ICA. 
- **Subordinate Infrastructure (`sub1.internal`)**: A nested, second-level deployment. Operates autonomously using an ICA signed by `top.internal`.

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
