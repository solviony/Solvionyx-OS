#!/usr/bin/env python3
import gi,requests,os
gi.require_version("Gtk","3.0")
from gi.repository import Gtk

def ask(p):
    env={}
    for line in open("/etc/solvy/solvy.env"):
        if "=" in line:
            k,v=line.strip().split("=",1)
            env[k]=v.strip('"')
    h={"Authorization":f"Bearer {env['OPENAI_API_KEY']}"}
    d={"model":"gpt-5.1","messages":[{"role":"user","content":p}]}
    r=requests.post("https://api.openai.com/v1/chat/completions",headers=h,json=d)
    return r.json()["choices"][0]["message"]["content"]

class App(Gtk.Window):
    def __init__(self):
        super().__init__(title="Solvy Assistant")
        self.set_default_size(600,500)
        box=Gtk.Box(orientation=Gtk.Orientation.VERTICAL,spacing=6)
        self.add(box)
        self.text=Gtk.TextView()
        box.pack_start(self.text,True,True,0)
        self.entry=Gtk.Entry()
        self.entry.connect("activate",self.send)
        box.pack_end(self.entry,False,False,0)

    def send(self,w):
        p=self.entry.get_text(); self.entry.set_text("")
        r=ask(p)
        buf=self.text.get_buffer()
        buf.insert(buf.get_end_iter(),f"You: {p}\nSolvy: {r}\n\n")

win=App(); win.connect("destroy",Gtk.main_quit); win.show_all(); Gtk.main()
