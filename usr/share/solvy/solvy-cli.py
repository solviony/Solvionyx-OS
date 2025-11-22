import os,sys,requests
env={}
for line in open("/etc/solvy/solvy.env"):
    if "=" in line:
        k,v=line.strip().split("=",1)
        env[k]=v.strip('"')

def ask(p):
    h={"Authorization":f"Bearer {env['OPENAI_API_KEY']}"}
    d={"model":"gpt-5.1","messages":[{"role":"user","content":p}]}
    r=requests.post("https://api.openai.com/v1/chat/completions",headers=h,json=d)
    return r.json()["choices"][0]["message"]["content"]

if __name__=="__main__":
    print(ask(" ".join(sys.argv[1:])))
