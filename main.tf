resource "proxmox_lxc" "container" {
  hostname    = var.vm_name
  target_node = var.target_node

  # Template LXC (toujours sur 'local', pas sur LVM)
  ostemplate = var.template_name != "" ? "local:vztmpl/${var.template_name}" : null

  # Ressources
  cores  = var.vm_cores
  memory = var.vm_memory

  # Configuration de base
  ostype       = "debian"
  unprivileged = true
  onboot       = true
  start        = true

  # Disque racine
  rootfs {
    storage = var.vm_storage
    size    = var.vm_disk_size
  }

  # Network
  network {
    name   = "eth0"
    bridge = var.vm_network_bridge
    ip     = "dhcp"
  }

  # Mot de passe root
  password = var.ci_password != "" ? var.ci_password : null

  # Clés SSH (optionnel)
  ssh_public_keys = var.ssh_keys != "" ? var.ssh_keys : null

  # ========================================
  # PROVISIONER ANSIBLE
  # ========================================
  # Un "provisioner" = code qui s'exécute APRÈS la création de la ressource
  # Ici, on lance Ansible pour installer Apache après que le container soit créé

  provisioner "local-exec" {
    # "local-exec" = exécute une commande sur votre MACHINE LOCALE (pas dans le container)
    # Autre option : "remote-exec" = exécute dans le container
    # On utilise local-exec car on lance ansible-playbook depuis notre machine

    interpreter = ["/bin/bash", "-c"]

    command = <<-EOT
      set -e

      echo "⏳ Attente 25s du démarrage complet..."
      sleep 25

      CONTAINER_NAME="${var.vm_name}"
      API_BASE_URL="${var.pm_api_url}"
      API_BASE_URL="$${API_BASE_URL%/api2/json}"

      echo "🔍 Récupération VMID..."
      RESPONSE=$(curl -k -s -H "Authorization: PVEAPIToken=${var.pm_api_token_id}=${var.pm_api_token_secret}" \
        "$API_BASE_URL/api2/json/nodes/${var.target_node}/lxc" 2>/dev/null)

      VMID=$(echo "$RESPONSE" | grep -o "{[^}]*\"name\":\"$CONTAINER_NAME\"[^}]*}" | \
        grep -o "\"vmid\":[0-9]*" | grep -o "[0-9]*" | sort -n | tail -1)

      echo "✅ VMID: $VMID"

      echo "🔍 Récupération IP via API..."
      CONTAINER_IP=""

      for i in {1..10}; do
        NETWORK_RESPONSE=$(curl -k -s -H "Authorization: PVEAPIToken=${var.pm_api_token_id}=${var.pm_api_token_secret}" \
          "$API_BASE_URL/api2/json/nodes/${var.target_node}/lxc/$VMID/interfaces" 2>/dev/null)

        CONTAINER_IP=$(echo "$NETWORK_RESPONSE" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -v "127.0.0.1" | head -1)

        if [ -n "$CONTAINER_IP" ]; then
          echo "✅ IP trouvée: $CONTAINER_IP"
          break
        fi

        echo "Tentative $i/10..."
        sleep 2
      done

      if [ -z "$CONTAINER_IP" ]; then
        echo "❌ IP non trouvée après 10 tentatives"
        exit 1
      fi

      echo ""
      echo "========================================="
      echo "🔑 TEST SSH"
      echo "========================================="

      for i in {1..20}; do
        echo "Test SSH $i/20 vers $CONTAINER_IP..."
        if ssh -i id_ed25519_terraform -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$CONTAINER_IP 'echo "SSH OK"' 2>/dev/null; then
          echo "✅ SSH fonctionne !"
          break
        fi
        sleep 3
      done

      echo ""
      echo "========================================="
      echo "🚀 LANCEMENT D'ANSIBLE"
      echo "========================================="

      # Vérifie qu'Ansible est installé
      if ! command -v ansible-playbook &> /dev/null; then
        echo "❌ Erreur : Ansible n'est pas installé !"
        echo "Installez-le avec : brew install ansible"
        exit 1
      fi

      # Vérifie que sshpass est installé (nécessaire pour passer le mot de passe)
      if ! command -v sshpass &> /dev/null; then
        echo "❌ Erreur : sshpass n'est pas installé !"
        echo "Installez-le avec : brew install hudochenkov/sshpass/sshpass"
        exit 1
      fi

      echo "📌 Target : $CONTAINER_IP"
      echo "📌 User   : root"
      echo "📌 Playbook : install_apache.yml"
      echo ""

      # Lance le playbook Ansible avec la clé SSH
      # --private-key = utilise la clé privée SSH
      # -i = inventaire (IP du container)
      # -u = utilisateur root
      ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook \
        --private-key=id_ed25519_terraform \
        -i "$CONTAINER_IP," \
        -u root \
        install_apache.yml

      # Vérifie le code de retour d'Ansible
      if [ $? -eq 0 ]; then
        echo "✅ Apache installé avec succès !"
        echo "🌐 Accédez à : http://$CONTAINER_IP"
      else
        echo "❌ Erreur lors de l'installation d'Apache"
        exit 1
      fi
    EOT
    # Fin du script bash

    # Le provisioner ne s'exécute que quand la ressource est CRÉÉE
    # Si vous faites "terraform apply" sur un container déjà existant,
    # le provisioner ne se relance PAS
  }
}
