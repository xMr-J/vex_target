fx_version 'cerberus'
game 'rdr3'

author 'VEX Development'
description 'VEX visual raycast selector and entity targeting utility for RedM'
version '1.0.0'

lua54 'yes'

dependencies {
    'vex_core',
    'vex_callback',
    'vex_textui'
}

shared_scripts {
    'config.lua'
}

client_scripts {
    'client/main.lua'
}

server_scripts {
    'server/main.lua'
}