declare -A infoconf=( ['name']="" ['mdpr']="" ['domain']="" ['mdpy']="" )
declare -A infoecho=( ['name']="Nom du lxc : " ['mdpr']="Password root : " ['domain']="Votre domaine (example.org) : " ['mdpy']="Password Yunohost : " )
declare -A comafaire=( ['0']="apt-get update" ['1']="apt-get upgrade -y" ['2']="apt-get update" ['3']="apt-get upgrade -y" ['4']="apt-get update" ['5']="yunohost tools postinstall -d ${infoconf[domain]} -p ${infoconf[mdpy]}" )


numero=$(lxc ls | grep -E '(RUNNING|STOPPED)' | wc -l)

while getopts "n:p:d:y:" option; do
    case "${option}" in
         n)
             infoconf[name]=${OPTARG}
             ;;
         p)
             infoconf[mdpr]=${OPTARG}
             ;;
         d)
             infoconf[domain]=${OPTARG}
             ;;
         y)
             infoconf[mdpy]=${OPTARG}
             ;;
    esac
done

for i in "${!infoconf[@]}"
    do if [ -z "${infoconf[$i]}" ];then
        read -p "${infoecho[$i]}" infoconf[$i]
    fi
done

x=0
while x=0; do
    if [ -n "$(cat /etc/haproxy/haproxy.cfg | grep ${infoconf[domain]})" ];then
        read -p "Le domaine est invalide ! Entrez votre domaine :" infoconf[domain] 
    else
        x=1
    fi
done

if [ -n "$(lxc image list | grep Yunim)" ];then
    echo "Yunim présent"
else
    lxc image import Yunim.tar.gz
    lxc image alias create Yunim bd9bc65cf113
fi

if [ -d "loglxc" ];then
    echo "Dossier log existant"
else
    mkdir loglxc
fi



lxc launch Yunim ${infoconf[name]} -c security.privileged=true > loglxc/"${infoconf[name]}".log 2>&1
lxc exec ${infoconf[name]} -- echo root:${infoconf[mdpr]} | lxc exec ${infoconf[name]} -- chpasswd

for i in "${comafaire[@]}"
    do lxc exec ${infoconf[name]} -- $i >> loglxc/"${infoconf[name]}".log 2>&1
done


lxc exec ${infoconf[name]} -- yunohost tools postinstall -d ${infoconf[domain]} -p ${infoconf[mdpy]} >> loglxc/"${infoconf[name]}".log 2>&1


######################################################### MODIFs PARTIE CERTIFICATS##########################################


#########################NO. CONTENEUR############################
#Determiner le nombre total de conteneurs creés pour créer la config du conteneur suivant

nomCon=$(lxc ls | grep -E '(RUNNING|STOPPED)' | wc -l)
prochain=$((nomCon++))

if [ $numero -ne 0 ] ; then
#####################CONF HAPROXY HTTP ET CERTS###########################

#Config HAproxy pour qu'il ecoute d'abord sur le port 80 et donc pouvoir creer le certificat (il faut que le conteneur puisse d'abord être accessible en HTTP)

#Creation des lignes pour la nouvelle ACL et le nouveau backend dans le même frontend
sed -i "/use_backend bk_web1/ i \    acl host_web$prochain hdr(host) -i ${infoconf[domain]}" "/etc/haproxy/haproxy.cfg"
sed -i "/use_backend bk_web$numero/ a \    use_backend bk_web$prochain if host_web$prochain" "/etc/haproxy/haproxy.cfg"

#Reperer l'IP du conteneur crée
ipconteneur=$(lxc ls | grep -w ${infoconf[name]} | cut -d"|" -f4 | cut -d" " -f2)

#Création du nouveau backend
(
cat <<back                                              

backend bk_web$prochain
    mode http
    option forwardfor
    http-request set-header X-Client-IP %[src]
    server web $ipconteneur:80 check

back
) >> /etc/haproxy/haproxy.cfg

service haproxy restart

#######################CREATION CERTIFICAT YUNOHOST##################

#lxc exec ${infoconf[name]} -- "echo '127.0.0.1 ${infoconf[domain]}' >> /etc/hosts"
lxc exec ${infoconf[name]} -- yunohost domain cert-install ${infoconf[domain]}

###########################################################################
#Ajouter le nouveau certificat dans le meme frontend

pathcont="${infoconf[name]}/etc/yunohost/certs/${infoconf[domain]}/"
pathhaproxy="/etc/haproxy/certs"
pathcert=$pathhaproxy/${infoconf[domain]}/${infoconf[domain]}.pem

lxc file pull -r $pathcont $pathhaproxy

#Merger les deux fichiers du certificat dans un seul fichier pour que HAproxy puisse le traiter. HAproxy reconnait uniquement ce format ou on dit 
#que le gère plus facilement (selon ce que j'ai lu sur internet)
cat $pathhaproxy/${infoconf[domain]}/crt.pem $pathhaproxy/${infoconf[domain]}/key.pem >> $pathcert

#Ajouter le chemin du nouveau certificat dans le même frontend
pathcertsed="\/etc\/haproxy\/certs\/${infoconf[domain]}\/${infoconf[domain]}.pem"
sed -i "/bind :::443.*/ s/$/ crt $pathcertsed/" "/etc/haproxy/haproxy.cfg"

service haproxy restart

########################CONFIG HAPROXY HTTPS####################
#Modification du backend du conteneur pour que maintenant il puisse être accessible en HTTPS

sed -i "/server web $ipconteneur:80 check/ c \    server web $ipconteneur:443 check ssl verify none" "/etc/haproxy/haproxy.cfg"

service haproxy restart

else

#Création du premier frontend et backend

(
cat <<front                                              

frontend ft_web1
    bind :::80 v4v6
    bind :::443 v4v6 ssl crt 
    mode http
    acl host_web1 hdr(host) -i ${infoconf[domain]}
    use_backend bk_web1 if host_web1

front
) >> /etc/haproxy/haproxy.cfg

(
cat <<back                                              

backend bk_web1
    mode http
    option forwardfor
    http-request set-header X-Client-IP %[src]
    server web $ipconteneur:80 check

back
) >> /etc/haproxy/haproxy.cfg

service haproxy restart

fi

