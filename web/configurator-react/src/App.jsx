import { useMemo, useState } from "react";

const CATALOG = [
  { id: "web", label: "Apache", playbook: "install_apache.yml", cores: 2, memory: 2048, disk: "10G" },
  { id: "glpi", label: "GLPI", playbook: "install_glpi.yml", cores: 2, memory: 4096, disk: "20G" },
  { id: "monitoring", label: "Uptime Kuma", playbook: "install_uptime_kuma.yml", cores: 2, memory: 2048, disk: "15G" },
  { id: "adguard", label: "AdGuard", playbook: "install_adguard.yml", cores: 1, memory: 1024, disk: "8G" },
  { id: "dc", label: "Active Directory", playbook: "install_ad_ds.yml", cores: 4, memory: 4096, disk: "60G" },
];

const DEFAULT_ENV = {
  proxmoxApiUrl: "https://192.168.68.200:8006/api2/json",
  proxmoxTokenId: "root@pam!terraform",
  proxmoxTokenSecret: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  targetNode: "proxmox",
  templateName: "debian-12-standard_12.12-1_amd64.tar.zst",
  vmStorage: "local-lvm",
  vmNetworkBridge: "vmbr0",
  ciUser: "sio2027",
  ciPassword: "Formation13@",
  windowsTemplateId: "WSERVER-TEMPLATE",
  windowsAdminPassword: "Admin123@",
  sshKeys: "",
};

const DEFAULT_AD = {
  domainName: "gsb.local",
  domainNetbios: "GSB",
  safeModePassword: "SafeMode123@",
  adminPassword: "Admin123@",
  defaultUserPassword: "User123@",
  usersOuName: "Utilisateurs_GSB",
  ousCsv: "Utilisateurs_GSB,Ordinateurs_GSB,Serveurs_GSB",
  dnsCsv: "8.8.8.8,8.8.4.4",
};

function buildInitialServices() {
  const obj = {};
  CATALOG.forEach((s) => {
    obj[s.id] = { enabled: s.id === "web", name: s.id, cores: s.cores, memory: s.memory, disk: s.disk, playbook: s.playbook };
  });
  return obj;
}

function csvList(input) {
  return input
    .split(",")
    .map((v) => v.trim())
    .filter(Boolean);
}

function downloadFile(filename, content) {
  const blob = new Blob([content], { type: "text/plain;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}

function toBase64Utf8(text) {
  const bytes = new TextEncoder().encode(text);
  let binary = "";
  bytes.forEach((b) => {
    binary += String.fromCharCode(b);
  });
  return window.btoa(binary);
}

export default function App() {
  const [env, setEnv] = useState(DEFAULT_ENV);
  const [ad, setAd] = useState(DEFAULT_AD);
  const [vmPrefix, setVmPrefix] = useState("SIO2027");
  const [services, setServices] = useState(buildInitialServices);
  const [copied, setCopied] = useState("");

  const selectedServices = useMemo(
    () => CATALOG.filter((s) => services[s.id]?.enabled).map((s) => services[s.id]),
    [services]
  );

  const envLocal = useMemo(
    () => `PROXMOX_API_URL=${env.proxmoxApiUrl}
PROXMOX_TOKEN_ID=${env.proxmoxTokenId}
PROXMOX_TOKEN_SECRET=${env.proxmoxTokenSecret}
TARGET_NODE=${env.targetNode}
TEMPLATE_NAME=${env.templateName}
VM_STORAGE=${env.vmStorage}
VM_NETWORK_BRIDGE=${env.vmNetworkBridge}
SSH_KEYS="${env.sshKeys}"
CI_USER=${env.ciUser}
CI_PASSWORD=${env.ciPassword}
WINDOWS_TEMPLATE_ID=${env.windowsTemplateId}
WINDOWS_ADMIN_PASSWORD=${env.windowsAdminPassword}
`,
    [env]
  );

  const tfVars = useMemo(() => {
    const entries = selectedServices
      .map(
        (svc) => `  "${svc.name}" = {
    cores     = ${Number(svc.cores) || 1}
    memory    = ${Number(svc.memory) || 1024}
    disk_size = "${svc.disk || "10G"}"
    playbook  = "${svc.playbook}"
  }`
      )
      .join("\n");

    return `# Genere par React configurator
pm_api_url          = "${env.proxmoxApiUrl}"
pm_api_token_id     = "${env.proxmoxTokenId}"
pm_api_token_secret = "${env.proxmoxTokenSecret}"

vm_name           = "${vmPrefix}"
target_node       = "${env.targetNode}"
template_name     = "${env.templateName}"
vm_storage        = "${env.vmStorage}"
vm_network_bridge = "${env.vmNetworkBridge}"

ci_user     = "${env.ciUser}"
ci_password = "${env.ciPassword}"
ssh_keys    = "${env.sshKeys}"

windows_template_id    = "${env.windowsTemplateId}"
windows_admin_password = "${env.windowsAdminPassword}"

vms = {
${entries || "  # Aucun service selectionne"}
}
`;
  }, [env, selectedServices, vmPrefix]);

  const adYaml = useMemo(() => {
    const dns = csvList(ad.dnsCsv).map((ip) => `  - "${ip}"`).join("\n") || '  - "8.8.8.8"';
    const ous = csvList(ad.ousCsv).map((ou) => `  - "${ou}"`).join("\n") || '  - "Utilisateurs_GSB"';
    return `domain_name: "${ad.domainName}"
domain_netbios: "${ad.domainNetbios}"
safe_mode_password: "${ad.safeModePassword}"
admin_password: "${ad.adminPassword}"
default_user_password: "${ad.defaultUserPassword}"
users_ou_name: "${ad.usersOuName}"
ad_admin_group: "Admins_GSB"

ad_admin_user:
  name: "admin.gsb"
  firstname: "Admin"
  surname: "GSB"

dns_forwarders:
${dns}

ad_ous:
${ous}

ad_test_users:
  - name: "user1.gsb"
    firstname: "Utilisateur"
    surname: "Un"
  - name: "user2.gsb"
    firstname: "Utilisateur"
    surname: "Deux"
  - name: "user3.gsb"
    firstname: "Utilisateur"
    surname: "Trois"
`;
  }, [ad]);

  const installCommand = useMemo(() => {
    const envB64 = toBase64Utf8(envLocal);
    const tfB64 = toBase64Utf8(tfVars);
    const adB64 = toBase64Utf8(adYaml);
    return `bash ./scripts/install_from_generated_config.sh '${envB64}' '${tfB64}' '${adB64}'`;
  }, [envLocal, tfVars, adYaml]);

  async function copy(name, content) {
    await navigator.clipboard.writeText(content);
    setCopied(name);
    setTimeout(() => setCopied(""), 1200);
  }

  function updateService(id, key, value) {
    setServices((prev) => ({ ...prev, [id]: { ...prev[id], [key]: value } }));
  }

  return (
    <div className="page">
      <header className="hero">
        <h1>Auto GSB Configurator</h1>
        <p>React UI pour preparer toute la config: Linux + Active Directory</p>
      </header>

      <section className="card">
        <h2>Base Proxmox</h2>
        <div className="grid">
          <label>API URL<input value={env.proxmoxApiUrl} onChange={(e) => setEnv({ ...env, proxmoxApiUrl: e.target.value })} /></label>
          <label>Token ID<input value={env.proxmoxTokenId} onChange={(e) => setEnv({ ...env, proxmoxTokenId: e.target.value })} /></label>
          <label>Token Secret<input value={env.proxmoxTokenSecret} onChange={(e) => setEnv({ ...env, proxmoxTokenSecret: e.target.value })} /></label>
          <label>Target Node<input value={env.targetNode} onChange={(e) => setEnv({ ...env, targetNode: e.target.value })} /></label>
          <label>Template Linux<input value={env.templateName} onChange={(e) => setEnv({ ...env, templateName: e.target.value })} /></label>
          <label>Storage<input value={env.vmStorage} onChange={(e) => setEnv({ ...env, vmStorage: e.target.value })} /></label>
          <label>Bridge / Network ID<input value={env.vmNetworkBridge} onChange={(e) => setEnv({ ...env, vmNetworkBridge: e.target.value })} /></label>
          <label>VM Prefix<input value={vmPrefix} onChange={(e) => setVmPrefix(e.target.value)} /></label>
          <label>Cloud-init User<input value={env.ciUser} onChange={(e) => setEnv({ ...env, ciUser: e.target.value })} /></label>
          <label>Cloud-init Password<input value={env.ciPassword} onChange={(e) => setEnv({ ...env, ciPassword: e.target.value })} /></label>
          <label>Windows Template<input value={env.windowsTemplateId} onChange={(e) => setEnv({ ...env, windowsTemplateId: e.target.value })} /></label>
          <label>Windows Admin Password<input value={env.windowsAdminPassword} onChange={(e) => setEnv({ ...env, windowsAdminPassword: e.target.value })} /></label>
        </div>
      </section>

      <section className="card">
        <h2>Services Linux + AD</h2>
        <div className="serviceList">
          {CATALOG.map((svc) => (
            <div key={svc.id} className="serviceItem">
              <label className="toggle">
                <input
                  type="checkbox"
                  checked={services[svc.id].enabled}
                  onChange={(e) => updateService(svc.id, "enabled", e.target.checked)}
                />
                <span>{svc.label}</span>
              </label>
              <label>Nom<input value={services[svc.id].name} onChange={(e) => updateService(svc.id, "name", e.target.value)} /></label>
              <label>CPU<input type="number" value={services[svc.id].cores} onChange={(e) => updateService(svc.id, "cores", e.target.value)} /></label>
              <label>RAM MB<input type="number" value={services[svc.id].memory} onChange={(e) => updateService(svc.id, "memory", e.target.value)} /></label>
              <label>Disque<input value={services[svc.id].disk} onChange={(e) => updateService(svc.id, "disk", e.target.value)} /></label>
            </div>
          ))}
        </div>
      </section>

      <section className="card">
        <h2>Active Directory</h2>
        <div className="grid">
          <label>Domaine<input value={ad.domainName} onChange={(e) => setAd({ ...ad, domainName: e.target.value })} /></label>
          <label>NetBIOS<input value={ad.domainNetbios} onChange={(e) => setAd({ ...ad, domainNetbios: e.target.value })} /></label>
          <label>Safe Mode Password<input value={ad.safeModePassword} onChange={(e) => setAd({ ...ad, safeModePassword: e.target.value })} /></label>
          <label>Admin Password<input value={ad.adminPassword} onChange={(e) => setAd({ ...ad, adminPassword: e.target.value })} /></label>
          <label>User Password (default)<input value={ad.defaultUserPassword} onChange={(e) => setAd({ ...ad, defaultUserPassword: e.target.value })} /></label>
          <label>OU Users<input value={ad.usersOuName} onChange={(e) => setAd({ ...ad, usersOuName: e.target.value })} /></label>
          <label>DNS Forwarders CSV<input value={ad.dnsCsv} onChange={(e) => setAd({ ...ad, dnsCsv: e.target.value })} /></label>
          <label>OUs CSV<input value={ad.ousCsv} onChange={(e) => setAd({ ...ad, ousCsv: e.target.value })} /></label>
        </div>
      </section>

      <section className="card outputs">
        <h2>Commande unique d installation</h2>
        <p>Depuis la racine du repo, cette commande ecrit la config en temporaire local puis lance le deploiement.</p>
        <div className="outBlock">
          <textarea readOnly value={installCommand} />
          <div className="actions">
            <button onClick={() => copy("commande-install", installCommand)}>Copier la commande</button>
          </div>
        </div>
      </section>

      <section className="card outputs">
        <h2>Fichiers generes</h2>
        <div className="outBlock">
          <h3>.env.local</h3>
          <textarea readOnly value={envLocal} />
          <div className="actions">
            <button onClick={() => copy(".env.local", envLocal)}>Copier</button>
            <button onClick={() => downloadFile(".env.local", envLocal)}>Telecharger</button>
          </div>
        </div>
        <div className="outBlock">
          <h3>terraform/terraform.tfvars</h3>
          <textarea readOnly value={tfVars} />
          <div className="actions">
            <button onClick={() => copy("terraform.tfvars", tfVars)}>Copier</button>
            <button onClick={() => downloadFile("terraform.tfvars", tfVars)}>Telecharger</button>
          </div>
        </div>
        <div className="outBlock">
          <h3>ansible/vars/ad_ds.yml</h3>
          <textarea readOnly value={adYaml} />
          <div className="actions">
            <button onClick={() => copy("ad_ds.yml", adYaml)}>Copier</button>
            <button onClick={() => downloadFile("ad_ds.yml", adYaml)}>Telecharger</button>
          </div>
        </div>
        {copied && <p className="copied">Copie: {copied}</p>}
      </section>
    </div>
  );
}
