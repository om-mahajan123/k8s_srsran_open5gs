import argparse
import os

def generate_ue_config(ue_number, output_directory):
    # Template for the configuration
    config_template = """
[rf]
freq_offset = 0
tx_gain = 80
rx_gain = 40
srate = 23.04e6
nof_antennas = 1

device_name = zmq
device_args = tx_port={tx_port},rx_port={rx_port},base_srate=23.04e6

[rat.eutra]
dl_earfcn = 2850
nof_carriers = 0

[rat.nr]
bands = 3
nof_carriers = 1
max_nof_prb = 106
nof_prb = 106

[log]
all_level = warning
phy_lib_level = none
all_hex_limit = 32
filename = {log_file}
file_max_size = 1000

[usim]
mode = soft
algo = milenage
opc  = E8ED289DEBA952E4283B54E88E6183CA
k    = 465B5CE8B199B49FAA5F0A2EE238A6BC
imsi = {imsi}
imei = 356938035643803

[rrc]
release = 15
ue_category = 4

[nas]
apn = internet
apn_protocol = ipv4

[gw]
netns = {netns}
ip_devname = tun_srsue
ip_netmask = 255.255.255.0

[gui]
enable = false
    """

    # Ensuring the output directory exists
    if not os.path.exists(output_directory):
        os.makedirs(output_directory)

    # Formatting the configuration with dynamic values
    config = config_template.format(
        tx_port=f"tcp://10.10.3.232:{2100 + ue_number}",
        rx_port=f"tcp://10.10.3.232:{2200 + ue_number}",
        log_file=os.path.join(output_directory, f"ue{ue_number}.log"),
        imsi=f"0010100000000{ue_number:02d}",
        netns=f"ue{ue_number}"
    )

    # Write the configuration file
    config_filename = os.path.join(output_directory, f"ue_{ue_number}.conf")
    with open(config_filename, 'w') as file:
        file.write(config)
    print(f"Configuration for UE{ue_number} written to {config_filename}")

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Generate a UE configuration file.')
    parser.add_argument('ue_number', type=int, help='User Equipment (UE) number')
    parser.add_argument('output_directory', type=str, help='Directory to save the UE configuration file')
    args = parser.parse_args()

    generate_ue_config(args.ue_number, args.output_directory)