#!/usr/bin/env python3
import os, time, requests, traceback
ENV="/etc/solvy/solvy.env"
LOG="/var/log/solvy.log"

def load():
    env={}
    if os.path.exists(ENV):
        for line in open(ENV):
            if "=" in line:
                k,v=line.strip().split("=",1)
                env[k]=v.strip('"')
    return env

def log(m):
    with open(LOG,"a") as f: f.write(m+"\n")

def ask(prompt,env):
    try:
        h={"Authorization":f"Bearer {env['OPENAI_API_KEY']}"}
        data={"model":env.get("SOLVY_MODEL","gpt-5.1"),
              "messages":[{"role":"user","content":prompt}]}
        r=requests.post("https://api.openai.com/v1/chat/completions",headers=h,json=data)
        r.raise_for_status()
        return r.json()["choices"][0]["message"]["content"]
    except Exception as e:
        log(str(e)); log(traceback.format_exc())
        return "Solvy Error"

def main():
    env=load()
    log("Solvy started")
    while True: time.sleep(5)

if __name__=="__main__": main()
