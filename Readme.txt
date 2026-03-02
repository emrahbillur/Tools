port.sh 

is a script that will allow you run a flash script image generation nixos configuration 
to copy all required items for flashing to a usb image that you can run this flash script in that usb 
on any linux host to flash a target device. This script copies all required nix store items and creates
a launcher.sh on your usb to run that flash script.

makediskimage.sh 

is a script that allows merging of esp.img.zst and root.img.zst into a single nixos.img.zst
with correct partition structure of nixos. Is used inside ghafdd.sh

ghafdd.sh
 is a script that allows you flash your nixos images onto usb drives where the script checks whether
the disk image exists or not, also if it is a two seperate image to be merged where it merges 
automatically and checks for the latest mounted usb and checks the image sized to fit that usb 
flashes your image to that usb. 


RUNNING:
-------------------------------------------------------------------------------------------------------------
You can add the ghafdd and makediskimage scripts in your nixos configuration like that to have them in your path. 
Replace /home/emrah/reps/Tools with your script locations.

  environment.systemPackages = with  pkgs; [
      wget
    # Personal
      (pkgs.writeShellScriptBin "ghafdd.sh" ''
         exec /home/emrah/reps/Tools/ghafdd.sh "$@"
      '')
      (pkgs.writeShellScriptBin "makediskimage.sh" ''
         exec /home/emrah/reps/Tools/makediskimage.sh "$@"
      '')   
  ];

For other OS you simply can add it to your PATH
