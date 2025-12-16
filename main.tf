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

    command = <<-EOT
      # Début du script bash multi-lignes (EOT = End Of Text)

      echo "⏳ Attente du démarrage du container..."
      sleep 45
      # Attend 45 secondes pour que :
      # - Le container démarre complètement
      # - Le réseau soit configuré
      # - SSH soit opérationnel

      echo "🔍 Test de connectivité SSH..."
      for i in {1..30}; do
        # Boucle : essaie 30 fois de se connecter en SSH
        # {1..30} = de 1 à 30

        if sshpass -p '${var.ci_password}' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${self.network[0].ip} 'echo SSH OK' 2>/dev/null; then
          # sshpass = permet de passer le mot de passe en ligne de commande
          # -p '${var.ci_password}' = mot de passe root
          # ssh options :
          #   -o StrictHostKeyChecking=no = n'ask pas de confirmer la clé
          #   -o UserKnownHostsFile=/dev/null = n'enregistre pas la clé
          # root@${self.network[0].ip} = user@IP
          #   ${self.network[0].ip} = IP du container (récupérée par Terraform)
          # 'echo SSH OK' = commande de test
          # 2>/dev/null = cache les erreurs

          echo "✅ SSH disponible !"
          break
          # Si la connexion réussit, sort de la boucle
        fi

        echo "Tentative $i/30..."
        sleep 2
        # Attend 2 secondes avant de réessayer
      done

      echo "🚀 Lancement d'Ansible..."

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

      # Lance le playbook Ansible
      ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook \
        -i '${self.network[0].ip},' \
        # -i = inventaire (liste des hôtes)
        # '${self.network[0].ip},' = IP du container
        # La virgule à la fin est IMPORTANTE : dit à Ansible que c'est une liste

        -u root \
        # -u root = utilisateur pour se connecter = root

        -e "ansible_password=${var.ci_password}" \
        # -e = extra variables (variables supplémentaires)
        # ansible_password = variable utilisée par Ansible pour se connecter
        # ${var.ci_password} = mot de passe root

        -e "ansible_sudo_pass=${var.ci_password}" \
        # Mot de passe sudo (même si on est déjà root)

        install_apache.yml
        # Nom du fichier playbook à exécuter

      # Vérifie le code de retour d'Ansible
      if [ $? -eq 0 ]; then
        echo "✅ Apache installé avec succès !"
        echo "🌐 Accédez à : http://${self.network[0].ip}"
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
