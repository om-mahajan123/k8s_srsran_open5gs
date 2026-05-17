## Bash file to start the UE using /opt/srsRAN_4G/build/srsue/src/srsue /srsran/config/ue1.conf
## The UE number is passed as an argument to the script

python3 /srsran/config/generate_ue_conf.py $1 /tmp/
ip netns add ue$1
/opt/srsRAN_4G/build/srsue/src/srsue /tmp/ue_$1.conf