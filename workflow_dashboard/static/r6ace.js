/* APPS to Container Refactor Engine v4 */
var R6P={current:0,status:{},bs:null,components:[],captureMethod:'smart',compatConfirmed:false,yaml:'',bundle:null,artifacts:{},preflight:{},continueBlocked:true,captureRun:null,creds:{cloud:{status:'not_configured',authUrl:'',region:'',credId:'',projectId:''},opencenter:{status:'not_configured',clusterRef:'rackspace-flex/flex-prod-k8s',gitDir:''},gitops:{status:'not_configured',localPath:'',branch:'main',method:'existing'}}};
var R6_SCAN_UI_VERSIONS=[{id:'scan-ui-v1',label:'Scan UI v1'}];
R6P.scanUiVersion='scan-ui-v1';try{localStorage.setItem('r6p_scan_ui_version','scan-ui-v1');}catch(e){}
/* Device-type badges for Stage 13 UAT rows - mirrors Stage 4's Component Test Lab
   (panel-s5c) classification/icon language so a component reads the same way
   (e.g. a Web/Mobile/Frontend component always shows the 📱 Mobile UI badge)
   whether you're testing it from the main dashboard or from inside R6. */
var R6_UAT_DEVICE_META={
  mobile_phone:       {icon:'📱',color:'#1d4ed8',label:'Mobile UI'},
  api_console_tablet: {icon:'📶',color:'#7c3aed',label:'API Console'},
  service_console:    {icon:'🖥️',color:'#0891b2',label:'Service Console'},
  backend_engine_rack:{icon:'⚙️',color:'#475569',label:'Backend Engine'},
  auth_security_device:{icon:'🔒',color:'#b45309',label:'Auth Device'},
  database_console:   {icon:'🗄️',color:'#b91c1c',label:'DB Console'},
  cache_memory_chip:  {icon:'⚡',color:'#c2410c',label:'Cache Chip'},
  queue_conveyor:      {icon:'📦',color:'#6d28d9',label:'Queue Belt'},
  worker_factory:      {icon:'🏭',color:'#334155',label:'Worker Factory'},
  monitoring_noc_wall: {icon:'📊',color:'#047857',label:'NOC Dashboard'}
};
window.r6pUatDeviceMeta=function(c){
  var r=((c.type||c.role||'')+' '+(c.name||'')).toLowerCase();
  var dt='service_console';
  if(r.indexOf('frontend')>=0||r.indexOf('mobile')>=0||(r.indexOf('web')>=0&&r.indexOf('gateway')<0))dt='mobile_phone';
  else if(r.indexOf('gateway')>=0)dt='api_console_tablet';
  else if(r.indexOf('auth')>=0||r.indexOf('sso')>=0||r.indexOf('identity')>=0)dt='auth_security_device';
  else if(r.indexOf('backend')>=0||r.indexOf('core')>=0||r.indexOf('ledger')>=0)dt='backend_engine_rack';
  else if(r.indexOf('database')>=0||r.indexOf('postgres')>=0||r.indexOf('mysql')>=0||r.indexOf('db')>=0)dt='database_console';
  else if(r.indexOf('cache')>=0||r.indexOf('redis')>=0)dt='cache_memory_chip';
  else if(r.indexOf('queue')>=0||r.indexOf('rabbit')>=0||r.indexOf('kafka')>=0)dt='queue_conveyor';
  else if(r.indexOf('worker')>=0||r.indexOf('cron')>=0||r.indexOf('batch')>=0)dt='worker_factory';
  else if(r.indexOf('monitor')>=0||r.indexOf('observ')>=0||r.indexOf('logging')>=0)dt='monitoring_noc_wall';
  else if(r.indexOf('api')>=0||r.indexOf('service')>=0)dt='service_console';
  return R6_UAT_DEVICE_META[dt];
};
var R6P_TOOLS=[
  {name:'git',        req:true,  note:'GitOps commit',           manual:false},
  {name:'curl',       req:true,  note:'CLI installers',          manual:false},
  {name:'jq',         req:true,  note:'JSON parsing',            manual:false},
  {name:'kubectl',    req:true,  note:'Cluster validation',      manual:false},
  {name:'flux',       req:true,  note:'Flux reconcile',          manual:false},
  {name:'openstack',  req:true,  note:'Cloud API / token test',  manual:false},
  {name:'opencenter', req:true,  note:'Cluster metadata',        manual:true},
  {name:'helm',       req:false, note:'Helm chart validation',   manual:false},
  {name:'yq',         req:false, note:'YAML processing',         manual:false},
  {name:'kustomize',  req:false, note:'Kustomize validation',    manual:false}
];
var R6P_STEPS=[{n:0,label:'Preflight',title:'Preflight Check',desc:'Verify CLI tools, FLEX/OpenStack credentials, SSH access, registry, GitOps repository, Kubernetes/OpenCenter access and required platform capabilities.'},{n:1,label:'Input',title:'Select Source Business Apps System',desc:'Import the complete FLEX Business Apps System: VMs, applications, databases, volumes, networks, IPs, ports, load balancers and dependencies.'},{n:2,label:'Refresh',title:'Refresh FLEX Inventory',desc:'Confirm current VM IDs, states, IPs, attached volumes, networks and existing snapshot metadata.'},{n:3,label:'Live Scan',title:'Live Scan Application VMs',desc:'Use read-only SSH to discover processes, services, ports, runtimes, startup commands, files, mounts, users and active dependencies.'},{n:4,label:'Components',title:'Map Components',desc:'Convert VM-level evidence into frontend, API, backend, worker, scheduler, database, cache, queue and storage components.'},{n:5,label:'Dependencies',title:'Map Dependencies',desc:'Define consumer/provider relationships, protocols, ports, current endpoints, authentication, TLS and startup order.'},{n:6,label:'Normalize',title:'Normalize Discovery Evidence',desc:'Merge imported topology and live inspection results; mark unreachable VMs and available snapshot fallback evidence.'},{n:7,label:'Classify',title:'Classify Components & Portability',desc:'Classify each component as stateless, stateful, mixed or unknown; assess licensing, hardware, identity and portability constraints.'},{n:8,label:'Decide',title:'Containerization Decision & Risk',desc:'Decide the target for every component: container, partial container, Kubernetes-native, operator-managed, retained VM, redeployed VM, external service, separate data migration or blocked.'},{n:9,label:'Capture+Build',title:'Capture Source & Build Images',desc:'Snapshot only approved container targets, safely extract application files, sanitize the build context, build/test/scan/sign/push images and preserve VM artifacts.'},{n:10,label:'GitOps',title:'Generate Kubernetes & GitOps',desc:'Generate workloads, Services, PVCs, NetworkPolicies, Gateway, operators, monitoring, backup, validation Jobs, Kustomize and Flux resources.'},{n:11,label:'Bundle',title:'Generate OpenCenter Bundle',desc:'Assemble the unified Business System bundle containing Kubernetes, VM, network, storage, DNS, LB, SG, validation and rollback requirements.'},{n:12,label:'Deploy',title:'Deploy to OpenCenter',desc:'Validate the bundle, copy it into managed-services/, commit and push GitOps changes, and trigger Flux reconciliation.'},
{n:13,label:'Validate+Cutover',title:'Validate, UAT & Cutover',desc:'Run Kubernetes validation Jobs, migrate data, execute business UAT, ramp traffic and trigger rollback when thresholds fail.'},
{n:14,label:'Report',title:'Final Report & Day-2 Operations',desc:'Produce transformation evidence and register monitoring, backup, scaling, drift detection, upgrades and rollback procedures.'}];
var R6P_MAX_STEP=Math.max.apply(null,R6P_STEPS.map(function(s){return s.n;}));
/* The former Step 2 "Refresh FLEX Inventory" was display-only: it made no
   cloud/API call and produced no new evidence. Remove it from the executable UI. */
R6P_STEPS=R6P_STEPS.filter(function(s){return s.n!==2;});

function r6pAdjacentStep(n,direction){
  var nums=R6P_STEPS.map(function(s){return s.n;});
  var idx=nums.indexOf(n);
  if(idx<0)return direction>0?nums[0]:nums[nums.length-1];
  return nums[idx+direction];
}

var R6_DECISION_TABLE=[['Web Frontend','Stateless','Containerize and run multiple replicas','Deployment + Service + Gateway'],['Mobile Backend','Stateless','Containerize and autoscale','Deployment + Service'],['API Server','Stateless','Containerize independently','Deployment + Service'],['API Gateway','Usually stateless','Use API Gateway, load balancer or container gateway','Gateway API + Envoy Gateway'],['Core Banking Backend','Unknown/mixed','Containerize after externalizing state','Deployment initially'],['Backend Service','Stateless','Containerize independently','Deployment + Service'],['Worker','Stateless','Containerize and scale on queue depth','Deployment'],['Batch Worker','Stateless execution','Run as an isolated task/job','Kubernetes Job'],['Scheduler','Stateless execution','Use managed scheduling rather than VM crontab','CronJob'],['Webhook Receiver','Stateless','Containerize behind controlled ingress','Deployment + Service'],['Notification Service','Stateless','Containerize and connect to a queue','Deployment'],['Database','Stateful','Keep outside the application container; use a managed or dedicated database initially','Existing FLEX DB or operator-managed DB'],['Database Proxy','Stateless','Containerize separately','Deployment + Service'],['Cache','Stateful or disposable','Use a dedicated cache service; rebuild disposable data','Redis operator or external Redis'],['Session Store','Stateful','Use a dedicated Redis-like session service','Redis operator'],['Queue','Stateful','Use a dedicated managed or operator-controlled message service','RabbitMQ operator'],['Event Stream','Stateful','Use a dedicated streaming platform','Kafka/Strimzi operator'],['Search Service API','Stateless','Containerize the API separately from the index','Deployment + Service'],['Search Engine','Stateful','Use a dedicated search cluster','OpenSearch operator or external service'],['File Storage','Stateful','Use shared persistent storage such as EFS rather than container disk','Manila, CephFS, NFS or PVC'],['Object Storage','Stateful external service','Store documents and uploads outside the container','Swift or S3-compatible object storage'],['Upload Service','Stateless','Containerize; write uploaded objects externally','Deployment + object storage'],['Document Service','Mixed','Containerize processing logic; externalize documents','Deployment + object storage/PVC'],['Auth / SSO','Mixed','Containerize service with an external database or use managed identity','Operator/Deployment + external DB'],['Secrets Manager','Stateful security service','Use external managed secrets rather than embedding secrets','Vault or External Secrets'],['Monitoring','Platform capability','Use platform-level container monitoring','Prometheus and Grafana'],['Metrics Exporter','Stateless','Run as sidecar, agent or service','Sidecar/DaemonSet'],['Log Processor','Stateless','Run as cluster-level collector','DaemonSet'],['Tracing Collector','Mostly stateless','Containerize collector and externalize trace storage','OpenTelemetry Collector'],['Backup Service','Stateful output','Store backups outside the cluster','Velero + object storage'],['Legacy Adapter','Unknown/mixed','Containerize only after OS, library, device and licensing checks','Deployment after assessment']];
var R6_AUTO_RULES=[['Application stores sessions in local RAM','Move sessions to Redis or use signed tokens'],['Application stores uploads locally','Move uploads to object or shared file storage'],['Application connects to localhost database/cache','Replace with external service hostname'],['Configuration is embedded in application files','Externalize to ConfigMap'],['Password exists in configuration file','Move to Secret/secret manager'],['Process runs as root','Create non-root container user'],['Application writes throughout root filesystem','Identify required writable paths and make the rest read-only'],['No health endpoint exists','Generate technical health check or request application change'],['Only one production replica is configured','Recommend two or more replicas'],['Dependency uses a fixed FLEX IP','Replace with internal DNS/service name'],['Several unrelated processes run on one VM','Create separate containers per application responsibility'],['Database files are found on an attached volume','Exclude them from image build and create a data-migration plan'],['Cache data is disposable','Deploy a clean cache and allow it to warm up'],['Queue contains pending business messages','Require drain, replication or controlled cutover'],['Logs are written only to files','Redirect to stdout/stderr and central logging'],['Image uses latest','Use a version and preferably immutable digest'],['CPU and memory are unknown','Use observed FLEX metrics as initial requests and limits'],['Application requires local identity or hostname','Mark as mixed and require manual assessment'],['Hardware or license binding is detected','Mark BLOCKED or KEEP_EXTERNAL']];
var R6_CLASSIFY_ROWS=[['Web Frontend','Stateless','Containerize as Deployment + Service'],['API Gateway','Stateless','Replace with Gateway API or containerize custom gateway logic'],['API Server','Stateless','Containerize as Deployment + Service'],['Auth / SSO','Unknown / mixed','Containerize with external database or deploy with operator'],['Core Banking Backend','Unknown / mixed','Containerize after assessment; externalize database, sessions, files and secrets'],['Backend App Server','Unknown / mixed','Containerize after externalizing local state'],['Backend Service','Stateless','Containerize as Deployment + Service'],['ERP Backend','Unknown / mixed','Containerize only where vendor-supported'],['Integration API','Stateless','Containerize as Deployment + Service'],['Database','Stateful','Keep external initially or migrate later with a database operator'],['Cache','Unknown / mixed','Deploy with operator; rebuild if data is disposable'],['Queue','Stateful','Deploy with operator or use a managed queue'],['File Storage','Stateful','Migrate separately to PVC, NFS, CephFS or Manila'],['Object Storage','Stateful','Connect as external storage such as Swift or S3-compatible storage'],['Worker','Stateless','Containerize as a worker Deployment'],['Batch Worker','Stateless','Convert to Kubernetes Job'],['Scheduler','Stateless','Convert to CronJob or scheduler Deployment'],['Payment Connector','Stateless','Containerize as an isolated integration service'],['Search Service','Stateless','Containerize; connect to an external search engine'],['Reporting App','Unknown / mixed','Containerize application; store reports externally'],['Export Service','Stateless','Containerize as Deployment or Job'],['Product Catalog Backend','Stateless','Containerize with external database and cache'],['Ingestion Endpoint','Stateless','Containerize as Deployment + Service'],['Monitoring','Unknown / mixed','Replace with platform monitoring such as Prometheus and Grafana'],['Mobile Backend','Stateless','Containerize as Deployment + Service'],['Webhook Receiver','Stateless','Containerize as Deployment + Service'],['Notification Service','Stateless','Containerize; connect to queue, email, SMS or push providers'],['Session Store','Stateful','Deploy Redis with operator or use managed Redis'],['Database Proxy','Stateless','Containerize as Deployment + Service'],['NoSQL Database','Stateful','Keep external initially or deploy with database operator'],['Search Engine','Stateful','Deploy with operator or use external managed search'],['Event Stream','Stateful','Deploy with operator, such as Strimzi for Kafka'],['Dead-Letter Processor','Stateless','Containerize as worker Deployment'],['Audit Service','Stateless','Containerize; store audit data in external immutable storage'],['Fraud Detection','Stateless','Containerize as API, rules or event-processing service'],['Rules Engine','Stateless','Containerize as Deployment + Service'],['Document Service','Unknown / mixed','Containerize application; store documents externally'],['Upload Service','Stateless','Containerize; write files to object storage or PVC'],['ETL Job','Stateless','Convert to Job, CronJob or workflow pipeline'],['Backup Service','Stateful','Use platform backup service with external backup storage'],['Secrets Manager','Stateful','Keep external or deploy with operator'],['Policy Engine','Stateless','Containerize as sidecar or shared service'],['Metrics Exporter','Stateless','Containerize as sidecar, DaemonSet or Deployment'],['Log Processor','Stateless','Containerize as DaemonSet or Deployment'],['Tracing','Unknown / mixed','Containerize collectors; use external or persistent trace storage'],['External Partner Connector','Stateless','Containerize as Deployment + Service'],['Legacy Adapter','Unknown / mixed','Containerize after compatibility assessment']];
var R6_CLASSIFY={};
R6_CLASSIFY_ROWS.forEach(function(r){R6_CLASSIFY[r[0]]={state:r[1],decision:r[2]};});
window.r6pClassifyFor=function(name){
  if(R6_CLASSIFY[name])return R6_CLASSIFY[name];
  var base=String(name||'').split(/\s+[—–-]\s+/)[0].trim();
  if(R6_CLASSIFY[base])return R6_CLASSIFY[base];
  var n=(name||'').toLowerCase();
  if(n.indexOf('database')>=0||n.indexOf('db')>=0)return{state:'Stateful',decision:'Keep external initially or migrate later with a database operator'};
  if(n.indexOf('cache')>=0)return{state:'Unknown / mixed',decision:'Deploy with operator; rebuild if data is disposable'};
  if(n.indexOf('queue')>=0)return{state:'Stateful',decision:'Deploy with operator or use a managed queue'};
  return{state:'Unknown / mixed',decision:'Run live assessment before deciding'};
};
window.r6pBuildPipelineStepsRows=function(){
  var groupDesc='Inspect FLEX runtime and model the source system: refresh VM/network/volume details, scan reachable VMs, identify components, map dependencies, normalize evidence and record snapshot fallback availability. This grouped stage does not create new snapshots.';
  var rows=[];
  var groupHandled=false;
  R6P_STEPS.forEach(function(st){
    if(R6P_RESCAN_GROUP.indexOf(st.n)>=0){
      if(groupHandled)return;
      groupHandled=true;
      var lo=Math.min.apply(null,R6P_RESCAN_GROUP), hi=Math.max.apply(null,R6P_RESCAN_GROUP);
      var titles=R6P_STEPS.filter(function(s2){return R6P_RESCAN_GROUP.indexOf(s2.n)>=0;}).map(function(s2){return s2.label;}).join(' &rarr; ');
      rows.push({num:lo+'&ndash;'+hi,stage:'Inspect FLEX Runtime & Model Source System',title:titles,desc:groupDesc});
      return;
    }
    rows.push({num:st.n,stage:st.label,title:st.title,desc:st.desc});
  });
  return rows;
};
window.r6pRenderPipelineStepsTable=function(){
  var host=document.getElementById('r6p-pipeline-steps-body');if(!host)return;
  var rows=r6pBuildPipelineStepsRows();
  var body=rows.map(function(r){
    return '<tr><td style="font-weight:700;color:#0369a1;">'+r.num+'</td><td style="font-weight:600;">'+r.stage+'</td><td style="font-size:11px;color:#334155;">'+r.title+'</td><td style="font-size:11px;color:#475569;">'+r.desc+'</td></tr>';
  }).join('');
  host.innerHTML='<div style="font-weight:800;font-size:13px;color:#0f172a;margin-bottom:8px;">R6 Pipeline Steps</div>'
    +'<div style="overflow-x:auto;max-height:420px;overflow-y:auto;margin-bottom:10px;"><table class="r6p-table"><thead><tr><th>#</th><th>Stage</th><th>Title</th><th>What it does</th></tr></thead><tbody>'+body+'</tbody></table></div>'
    +'<div style="font-size:11px;color:#64748b;background:#f8fafc;border:1px solid #e2e8f0;border-radius:6px;padding:8px 12px;">Note: Steps 3&ndash;6 scan and model the source system without creating snapshots. Snapshot capture happens only in Stage 9 after Stage 8 approval.</div>';
};
window.r6pRenderClassifyChart=function(){
  var host=document.getElementById('r6p-classify-chart-inner')||document.getElementById('r6p-classify-chart-body');if(!host)return;
  var stColor={'Stateless':'#16a34a','Stateful':'#dc2626','Unknown / mixed':'#d97706'};
  var rows=R6_CLASSIFY_ROWS.map(function(r){
    var c=stColor[r[1]]||'#64748b';
    return '<tr><td style="font-weight:600;">'+r[0]+'</td><td><span style="background:'+c+'22;color:'+c+';padding:2px 8px;border-radius:999px;font-size:10px;font-weight:700;">'+r[1]+'</span></td><td style="font-size:11px;color:#475569;">'+r[2]+'</td></tr>';
  }).join('');
  var ruleRows=[['Stateless','Containerize'],['Stateful database or storage','Keep external initially or migrate separately'],['Stateful platform service','Deploy with operator'],['Unknown / mixed','Run live assessment before deciding'],['Kubernetes platform capability','Replace with platform service'],['Disposable cache data','Rebuild instead of migrate'],['Persistent cache, queue or session data','Migrate or replicate carefully']].map(function(r){
    return '<tr><td style="font-weight:600;">'+r[0]+'</td><td style="font-size:11px;color:#475569;">'+r[1]+'</td></tr>';
  }).join('');
  host.innerHTML='<div style="font-weight:800;font-size:13px;color:#0f172a;margin-bottom:8px;">Consolidated Component Containerization Table</div>'
    +'<div style="overflow-x:auto;max-height:360px;overflow-y:auto;margin-bottom:16px;"><table class="r6p-table"><thead><tr><th>Component</th><th>Stateless / Stateful / Unknown</th><th>Containerization Decision</th></tr></thead><tbody>'+rows+'</tbody></table></div>'
    +'<div style="font-weight:800;font-size:13px;color:#0f172a;margin-bottom:8px;">Recommended Automatic Decision Rules</div>'
    +'<div style="overflow-x:auto;"><table class="r6p-table"><thead><tr><th>Detected Classification</th><th>Default UI Decision</th></tr></thead><tbody>'+ruleRows+'</tbody></table></div>';
  var decRows=R6_DECISION_TABLE.map(function(r){
    return '<tr><td style="font-weight:600;">'+r[0]+'</td><td style="font-size:11px;color:#475569;">'+r[1]+'</td><td style="font-size:11px;color:#475569;">'+r[2]+'</td><td style="font-size:11px;color:#0369a1;font-weight:600;">'+r[3]+'</td></tr>';
  }).join('');
  var autoRuleRows=R6_AUTO_RULES.map(function(r){
    return '<tr><td style="font-size:11px;color:#334155;">'+r[0]+'</td><td style="font-size:11px;font-weight:600;color:#16a34a;">'+r[1]+'</td></tr>';
  }).join('');
  host.innerHTML+='<div style="font-weight:800;font-size:13px;color:#0f172a;margin:18px 0 8px;">Component Containerization Decision Table</div>'
    +'<div style="overflow-x:auto;max-height:420px;overflow-y:auto;margin-bottom:16px;"><table class="r6p-table"><thead><tr><th>Business-system component</th><th>State</th><th>AWS best-practice decision</th><th>Equivalent target for OpenCenter</th></tr></thead><tbody>'+decRows+'</tbody></table></div>'
    +'<div style="font-weight:800;font-size:13px;color:#0f172a;margin-bottom:8px;">Rules the Converter Enforces Automatically</div>'
    +'<div style="overflow-x:auto;max-height:320px;overflow-y:auto;margin-bottom:16px;"><table class="r6p-table"><thead><tr><th>Detection</th><th>Automatic Recommendation</th></tr></thead><tbody>'+autoRuleRows+'</tbody></table></div>'
    +'<div style="font-weight:800;font-size:13px;color:#0f172a;margin-bottom:8px;">Recommended Production Pattern</div>'
    +'<pre style="background:#0f172a;color:#7dd3fc;padding:14px;border-radius:8px;font-size:11px;line-height:1.5;overflow-x:auto;margin-bottom:14px;">External users\n      |\n      v\nGateway / Load Balancer\n      |\n      +-- Web Frontend replicas\n      |\n      +-- API Server replicas\n                |\n                v\n       Core Backend replicas\n          |       |       |\n          |       |       +-- Queue / Event Stream\n          |       +----------- Cache / Session Store\n          +------------------- External Database\n\nWorkers -----------------> Queue\nUploads/Documents -------> Object or shared storage\nLogs/Metrics/Traces -----> Central observability platform\nSecrets ------------------> External secret manager</pre>'
    +'<div style="background:#eff6ff;border:1px solid #bfdbfe;border-radius:8px;padding:12px 16px;font-size:12px;color:#1e40af;font-weight:600;line-height:1.6;">Package application execution in immutable containers, but keep configuration, credentials, sessions, databases, queues and persistent files outside those containers.</div>';
};
var R6_DELTA_COMPARE=[['Primary goal','Convert suitable application components into containers','Rebuild the entire Business Apps System using the best mix of containers, VMs, Kubernetes services and external services'],['Input','FLEX applications and VMs mainly inspected for containerization','Complete FLEX Business Apps System: VMs, networks, volumes, IPs, ports, security groups, load balancers and dependencies'],['Output','Docker images, Kubernetes manifests and references to external components','A complete deployable Business Apps System blueprint containing containers, VMs, networks, storage and all connections'],['Business-system identity','Produced container artifacts from the source system','Creates a new version of the same logical system, such as BankMobile FLEX v1 to BankMobile Hybrid v2'],['VM treatment','Non-container components were normally kept external or handed off separately','VMs are first-class target components: retained, redeployed or newly provisioned through OpenCenter'],['OpenCenter responsibility','Mainly deploy Kubernetes and GitOps artifacts','Deploy and manage the complete hybrid system: containers, VMs, networking, volumes, aliases and connectivity'],['Container decision','Containerize, operator-manage, keep external or block','Containerized, partially containerized, Kubernetes-native, operator-managed, retained VM, redeployed VM, external or blocked'],['Network handling','Mostly remapped application endpoints to Kubernetes Services','Reconstructs full network topology, routing, DNS, security groups, internal load balancers and NetworkPolicies'],['Storage handling','PVCs and external data-migration plans','Handles Kubernetes PVCs plus FLEX/OpenStack VM volumes, attachments, mount definitions and object storage'],['Dependency mapping','Mainly container-to-container and container-to-external','Supports all four paths: container to container, container to VM, VM to container and component to external service'],['VM artifacts','Limited retained-VM references','Full VM deployment definitions: image, flavor, network, security group, volumes, cloud-init, backup and health tests'],['Deployment bundle','Kubernetes/OpenCenter GitOps bundle','Unified OpenCenter Business System bundle with Kubernetes and OpenStack VM sections'],['Staging deployment','Deploy containers and validate external dependencies','OpenCenter provisions infrastructure and VMs, deploys containers, reconnects all components and validates the whole system'],['Cutover','Focused on application containers and migrated data','Validates complete business flows across containers, VMs, databases, storage, queues and gateways'],['Day-2 operations','Mostly Flux and Kubernetes operations','Unified application status, scaling, VM lifecycle, backup, upgrade, drift detection and rollback through OpenCenter']];
var R6_DELTA_STAGES=[['Select FLEX Business System','Import the complete application and infrastructure topology'],['Hydrate FLEX Inventory','Verify VMs, networks, volumes, endpoints and existing relationships'],['Runtime Inspection','Inspect application processes plus VM-specific runtime requirements'],['Component Detection','Build an application, infrastructure and network model'],['State Classification','Also assess portability, licensing, hardware and machine-identity requirements'],['Containerization Decision','Replaced by target-runtime selection for every component'],['Asset Extraction','Extract container assets and preserve complete VM deployment definitions'],['Readiness Assessment','Validate container readiness, VM deployability and hybrid connectivity'],['Target Architecture','Design the complete hybrid Business Apps System'],['Image Build','Build container images and prepare VM images, snapshots, cloud-init and volume definitions'],['GitOps Bundle','Generate a unified OpenCenter deployment blueprint'],['Staging Deployment','OpenCenter provisions VMs and infrastructure and deploys Kubernetes workloads'],['Cutover','Validate the entire container-and-VM business transaction path'],['Final Report','Register the system for OpenCenter day-2 management']];
var R6_DELTA_SCOPE=[['Containers and Kubernetes services','FluxCD, Helm, Kustomize and Kubernetes APIs'],['FLEX/OpenStack VMs and infrastructure','Terraform/OpenTofu and OpenStack APIs'],['VM volumes','Cinder provisioning and attachment'],['Kubernetes storage','CSI, StorageClasses and PVCs'],['Container-to-VM access','Kubernetes Service aliases and EndpointSlices'],['VM-to-container access','Internal load balancer, Gateway and private DNS'],['Network security','OpenStack security groups and Kubernetes NetworkPolicies'],['System validation','Component, dependency and end-to-end business tests']];
var R6_OC_PRODUCTION_PIPELINE=[
  ['Source capture gate','R6 Step 9 - snapshot only Stage 8-approved container sources, extract approved paths read-only, block secrets/database files, record source lineage'],
  ['Image build &amp; push','R6 Step 9 - Docker build, start test, SBOM (syft), vulnerability scan (trivy), sign (cosign), digest resolution, push to Harbor/Docker Hub/GHCR/GitLab/Quay/ECR/ECR Public/GCP/custom'],
  ['Kubernetes deploy','FluxCD + Kustomize, via the real GitOps repo overlay applications/overlays/&lt;cluster&gt;/managed-services/&lt;slug&gt;/'],
  ['GitOps commit/push','R6 Step 12 - real git add/commit/push, manual button or auto-chained from Step 9 Automatic mode'],
  ['Config source','Production panel (ocqp_state), not Quickstart - org/cluster/repo/SSH key all sync from the real production config'],
  ['VM provisioning (retained/redeployed)','Decided correctly by R6 (Step 8), not yet automated - real Terraform/OpenStack integration is documented as future work, not faked'],
  ['Bundle evidence','R6 writes source-capture-manifest.json, source-lineage.json, bundle-validation.json, image manifest, rollback runbook and validation jobs'],
  ['Post-deploy validation','R6 Step 13 UAT - kubectl exec into deployed pods or SSH to retained/redeployed VMs, real health-path checks, sign-off tracker']
];
var R6_HYBRID_PRODUCTION_ROWS=[
  ['0','Preflight Requirements Check','preflight-report.json: tools, credentials, registry, GitOps, Kubernetes/OpenCenter access','Blocks production until required local and platform access are present'],
  ['1','Import Source FLEX Business Apps System','source-business-system.json: VMs, DBs, networks, volumes, ports, dependencies','Defines the OpenCenter Business System identity and source topology'],
  ['3-6','Required discovery evidence','runtime-inspection.json, component-catalog.json, dependency graph, normalized discovery','Each discovery step feeds Stage 8 decisions; no snapshot is created before approval'],
  ['7','Extract Assets and Classify State/Portability','state-classification.json: stateless/stateful/mixed, files, config, secrets, DB data, portability risks','Determines which components are safe candidates and which require VM/operator/data paths'],
  ['8','Hybrid Containerization Decision Engine','component-decisions.json: container, partial container, operator, retained/redeployed VM, external, data migration, blocked','Hard approval gate for Stage 9 source capture and OpenCenter target runtime selection'],
  ['9','Capture Source &amp; Build Images','source-capture-manifest.json, source-lineage.json, Dockerfiles, image plan, SBOM, scan, signature, digest','Snapshots only approved container sources, sanitizes context, pushes immutable images, preserves VM artifacts'],
  ['10','Kubernetes YAML / Helm / Kustomize / Flux','Deployments, Services, PVCs, NetworkPolicies, Gateway, validation Jobs, Flux/Kustomize resources','Creates the GitOps payload OpenCenter reconciles into Kubernetes'],
  ['11','Generate Unified OpenCenter Blueprint','business-system.yaml plus Kubernetes, VM handoff, storage, network, validation and rollback requirements','Assembles the deployable OpenCenter-managed hybrid application bundle'],
  ['12','OpenCenter Hybrid Business System Deployment','GitOps overlay import, optional real git commit/push, Flux reconcile trigger','Deploys container resources; retained/redeployed VMs are validated or handed to FLEX/OpenStack workflow'],
  ['13','Cutover: Validate Hybrid Business Transaction Path','validation-evidence.json, UAT sign-off, DNS/LB commands, rollback decision points','Proves business flows across containers, VMs, databases, storage, queues and gateways'],
  ['14','Final Report and OpenCenter Day-2 Management','final report, day-2 registration, monitoring/backup/drift/rollback records','Registers the managed system for operations, scaling, backup, drift detection, upgrade and rollback']
];
window.r6pRenderHybridDeltaChart=function(){
  var host=document.getElementById('r6p-hybrid-delta-body');if(!host)return;
  var curRows=R6_HYBRID_PRODUCTION_ROWS.map(function(r){
    return '<tr><td style="font-weight:700;color:#0369a1;">'+r[0]+'</td><td style="font-weight:600;color:#0f172a;">'+r[1]+'</td><td style="font-size:11px;color:#475569;">'+r[2]+'</td><td style="font-size:11px;color:#166534;font-weight:600;">'+r[3]+'</td></tr>';
  }).join('');
  var ocRows=R6_OC_PRODUCTION_PIPELINE.map(function(r){
    return '<tr><td style="font-weight:600;">'+r[0]+'</td><td style="font-size:11px;color:#475569;">'+r[1]+'</td></tr>';
  }).join('');
  host.innerHTML=''
    +'<div style="font-weight:800;font-size:14px;color:#0f172a;margin-bottom:8px;">R6 Hybrid Refactor Pipeline (15 stages)</div>'
    +'<div style="overflow-x:auto;max-height:360px;overflow-y:auto;margin-bottom:18px;"><table class="r6p-table"><thead><tr><th>#</th><th>R6 Stage</th><th>R6 Output</th><th>OpenCenter Production Use</th></tr></thead><tbody>'+curRows+'</tbody></table></div>'
    +'<div style="font-weight:800;font-size:14px;color:#0f172a;margin-bottom:8px;">OpenCenter Production Pipeline</div>'
    +'<div style="overflow-x:auto;"><table class="r6p-table"><thead><tr><th>Area</th><th>Mechanism</th></tr></thead><tbody>'+ocRows+'</tbody></table></div>';
};
var R6P_BS_STORAGE_SIG='';
var R6P_SELECTED_BS_KEY='r6p_selected_business_system_id';
window.r6pScanRunStorageKey=function(){return 'r6p_latest_scan_run:'+(R6P.bs&&R6P.bs.id?String(R6P.bs.id):'none');};
window.r6pScanRunCacheKey=function(){return 'r6p_cached_scan_run:'+(R6P.bs&&R6P.bs.id?String(R6P.bs.id):'none');};
window.r6pCompactScanRunForCache=function(run){
  var copy=JSON.parse(JSON.stringify(run||{}));
  copy.liveLog=(copy.liveLog||[]).slice(-200);
  (copy.components||[]).forEach(function(c){(c.probes||[]).forEach(function(p){
    if(p.stdout&&String(p.stdout).length>6000)p.stdout=String(p.stdout).slice(-6000);
    if(p.stderr&&String(p.stderr).length>6000)p.stderr=String(p.stderr).slice(-6000);
  });});
  copy.cacheCompacted=true;
  return copy;
};
window.r6pRememberScanRun=function(runId){if(!runId)return;try{localStorage.setItem('r6p_latest_scan_run',runId);if(R6P.bs&&R6P.bs.id)localStorage.setItem(r6pScanRunStorageKey(),runId);}catch(e){}};
window.r6pCacheScanRun=function(run){
  if(!run||!run.runId)return;
  r6pRememberScanRun(run.runId);
  try{localStorage.setItem('r6p_cached_scan_run',JSON.stringify(run));if(R6P.bs&&R6P.bs.id)localStorage.setItem(r6pScanRunCacheKey(),JSON.stringify(run));return true;}catch(e){}
  try{sessionStorage.setItem('r6p_cached_scan_run',JSON.stringify(run));if(R6P.bs&&R6P.bs.id)sessionStorage.setItem(r6pScanRunCacheKey(),JSON.stringify(run));return true;}catch(eS){}
  try{var compact=r6pCompactScanRunForCache(run);localStorage.setItem('r6p_cached_scan_run',JSON.stringify(compact));if(R6P.bs&&R6P.bs.id)localStorage.setItem(r6pScanRunCacheKey(),JSON.stringify(compact));return true;}catch(e2){}
  try{var compact2=r6pCompactScanRunForCache(run);sessionStorage.setItem('r6p_cached_scan_run',JSON.stringify(compact2));if(R6P.bs&&R6P.bs.id)sessionStorage.setItem(r6pScanRunCacheKey(),JSON.stringify(compact2));return true;}catch(e3){return false;}
};
window.r6pLoadCachedScanRun=function(){
  try{
    var raw=localStorage.getItem(r6pScanRunCacheKey())||sessionStorage.getItem(r6pScanRunCacheKey())||localStorage.getItem('r6p_cached_scan_run')||sessionStorage.getItem('r6p_cached_scan_run');
    var run=raw?JSON.parse(raw):null;
    if(!run||!run.runId)return null;
    if(R6P.bs&&run.businessSystem&&run.businessSystem.id&&String(run.businessSystem.id)!==String(R6P.bs.id))return null;
    return run;
  }catch(e){return null;}
};
window.r6pScanViewCacheKey=function(){return 'r6p_cached_scan_view:'+(R6P.bs&&(R6P.bs.id||R6P.bs.name)?String(R6P.bs.id||R6P.bs.name):'none');};
window.r6pPersistScanView=function(run){
  var root=document.getElementById('r6p-scan-appraisal'),verdict=document.getElementById('r6p-scan-final-verdict'),failed=document.getElementById('r6p-scan-failed-checks');
  if(!run||!run.runId||!root)return false;
  var view={runId:run.runId,status:run.status||'',progress:run.progress||{},businessSystem:run.businessSystem||R6P.bs||{},savedAt:new Date().toISOString(),productionScanLog:R6P.productionScanLog||'',appraisalHtml:root.innerHTML,verdictHtml:verdict?verdict.innerHTML:'',failedHtml:failed?failed.innerHTML:''};
  try{localStorage.setItem('r6p_cached_scan_view',JSON.stringify(view));if(R6P.bs)localStorage.setItem(r6pScanViewCacheKey(),JSON.stringify(view));return true;}catch(e){}
  try{sessionStorage.setItem('r6p_cached_scan_view',JSON.stringify(view));if(R6P.bs)sessionStorage.setItem(r6pScanViewCacheKey(),JSON.stringify(view));return true;}catch(e2){return false;}
};
window.r6pLoadCachedScanView=function(){
  try{
    var raw=(R6P.bs&&(localStorage.getItem(r6pScanViewCacheKey())||sessionStorage.getItem(r6pScanViewCacheKey())))||localStorage.getItem('r6p_cached_scan_view')||sessionStorage.getItem('r6p_cached_scan_view');
    var view=raw?JSON.parse(raw):null;
    if(!view||!view.runId)return null;
    if(R6P.bs&&view.businessSystem&&view.businessSystem.id&&String(view.businessSystem.id)!==String(R6P.bs.id))return null;
    return view;
  }catch(e){return null;}
};
window.r6pRenderCachedScanView=function(view){
  if(!view||!view.runId)return false;
  R6P.scanRunId=view.runId;R6P.productionScanLog=view.productionScanLog||R6P.productionScanLog||'';
  var out=document.getElementById('r6p-production-scan-status');if(out){out.textContent=R6P.productionScanLog;out.scrollTop=out.scrollHeight;}
  var root=document.getElementById('r6p-scan-appraisal'),verdict=document.getElementById('r6p-scan-final-verdict'),failed=document.getElementById('r6p-scan-failed-checks');
  if(root&&view.appraisalHtml)root.innerHTML=view.appraisalHtml;
  if(verdict&&view.verdictHtml)verdict.innerHTML=view.verdictHtml;
  if(failed&&view.failedHtml)failed.innerHTML=view.failedHtml;
  return true;
};
window.r6pRenderCachedScanRun=function(run){
  if(!run||!run.runId)return false;
  R6P.scanRunId=run.runId;R6P.structuredAppraisal=run;
  r6pSetProductionScanLog(r6pFormatProductionScanLog(run));
  r6pRenderProductionAppraisal(run);
  return true;
};
window.r6pFetchLatestScanRunFromServer=function(){
  var qs=[];
  if(R6P.bs&&R6P.bs.id)qs.push('businessSystemId='+encodeURIComponent(R6P.bs.id));
  if(R6P.bs&&R6P.bs.name)qs.push('businessSystemName='+encodeURIComponent(R6P.bs.name));
  return fetch('/api/r6/scans/latest'+(qs.length?'?'+qs.join('&'):''),{cache:'no-store',headers:{'Cache-Control':'no-cache','Accept':'application/json'}})
    .then(function(r){if(!r.ok)return null;return r.json();})
    .then(function(run){
      if(!run||!run.ok||!run.runId)return null;
      if(R6P.bs&&run.businessSystem&&run.businessSystem.id&&String(run.businessSystem.id)!==String(R6P.bs.id))return null;
      r6pCacheScanRun(run);
      R6P.scanRunId=run.runId;R6P.structuredAppraisal=run;
      r6pSetProductionScanLog(r6pFormatProductionScanLog(run));
      r6pRenderProductionAppraisal(run);
      r6pPersistScanView(run);
      if(run.status==='RUNNING')r6pPollProductionScan();
      return run;
    }).catch(function(){return null;});
};
window.r6pRestoreScanRun=function(){
  var cached=r6pLoadCachedScanRun(),id=null;
  try{id=localStorage.getItem(r6pScanRunStorageKey())||localStorage.getItem('r6p_latest_scan_run');}catch(e){}
  var cachedView=r6pLoadCachedScanView();
  if(cachedView){id=cachedView.runId;r6pRenderCachedScanView(cachedView);}
  else if(cached){id=cached.runId;r6pRenderCachedScanRun(cached);}
  else{R6P.structuredAppraisal=null;}
  R6P.scanRunId=id||null;R6P.appraisalReviewed=false;
  var status=(cached&&cached.status)||(cachedView&&cachedView.status)||'';
  if(id&&status==='RUNNING')r6pPollProductionScan();
  if(typeof r6pFetchLatestScanRunFromServer==='function')r6pFetchLatestScanRunFromServer();
  return id;
};
window.r6pSyncSelectedBusinessSystem=function(force){
  var raw='[]';
  try{raw=localStorage.getItem('uatS1_systems')||'[]';}catch(e){}
  if(!force&&raw===R6P_BS_STORAGE_SIG)return;
  R6P_BS_STORAGE_SIG=raw;
  var systems=[];
  try{systems=JSON.parse(raw)||[];}catch(e){systems=[];}
  var selected=null;
  if(R6P.bs&&R6P.bs.id)selected=systems.find(function(s){return s.id===R6P.bs.id;})||null;
  if(!selected){
    var rememberedId='';
    try{rememberedId=localStorage.getItem(R6P_SELECTED_BS_KEY)||'';}catch(e){}
    if(rememberedId)selected=systems.find(function(s){return String(s.id)===rememberedId;})||null;
    if(rememberedId&&!selected)try{localStorage.removeItem(R6P_SELECTED_BS_KEY);}catch(e){}
  }
  if(selected){
    R6P.bs=selected;
    R6P.components=selected.components||[];
  }else if(R6P.bs&&R6P.bs.id){
    R6P.bs=null;
    R6P.components=[];
  }
  var si=document.getElementById('r6p-sum-input');
  if(si)si.textContent=(R6P.bs&&R6P.bs.name)||'No Business System selected';
  var sc=document.getElementById('r6p-sum-comps');
  if(sc)sc.textContent=((R6P.components||[]).length)+' components';
  if(selected&&typeof r6pMarkStep1Selected==='function')r6pMarkStep1Selected();
  if(typeof r6pLoadBiz==='function')r6pLoadBiz();
  if(typeof r6pRenderContainerReadyForm==='function')r6pRenderContainerReadyForm();
  if(typeof r6pRefreshComponentDrivenStages==='function')r6pRefreshComponentDrivenStages();
};
window.r6pRefreshComponentDrivenStages=function(){
  [3,4,5,6,7,8,9,13].forEach(function(n){
    var body=document.getElementById('r6p-body-'+n);
    if(!body)return;
    var inner=body.querySelector('.r6p-stage-body-inner');
    if(inner)inner.innerHTML=r6pContent(n);
  });
};
window.r6pComponentTarget=function(c){
  c=c||{};
  var nested=c.target||c.flex||c.vm||{};
  return String(c.tgt||c.targetIp||c.targetIP||c.target_ip||c.flexIp||c.flexIP||
    c.flex_ip||c.vmIp||c.vm_ip||c.ip||c.endpoint||c.host||
    nested.ip||nested.address||nested.endpoint||'').trim();
};
window.r6pInputConnectionFor=function(c){
  c=c||{};
  var target=r6pComponentTarget(c),targetHost='';
  try{targetHost=new URL(target.indexOf('://')>=0?target:'ssh://'+target).hostname;}catch(e){targetHost=target.replace(/^[a-z][a-z0-9+.-]*:\/\//i,'').split('/')[0].split(':')[0];}
  var directUser=String(c.sshUser||c.ssh_user||'').trim();
  var directKey=String(c.sshKeyPath||c.ssh_key_path||c.sshKey||c.ssh_key||'').trim();
  var matched=null,standalones=[];
  try{standalones=JSON.parse(localStorage.getItem('uatS1_standalones')||'[]')||[];}catch(e2){}
  var bsId=R6P.bs&&R6P.bs.id,compName=String(c.name||'').toLowerCase();
  var candidates=standalones.filter(function(item){
    if(item.mappedBsId&&bsId&&String(item.mappedBsId)!==String(bsId))return false;
    var itemTarget=String(item.target||''),itemHost='';
    try{itemHost=new URL(itemTarget.indexOf('://')>=0?itemTarget:'ssh://'+itemTarget).hostname;}catch(e3){itemHost=itemTarget.replace(/^[a-z][a-z0-9+.-]*:\/\//i,'').split('/')[0].split(':')[0];}
    return (targetHost&&itemHost===targetHost)||String(item.name||'').toLowerCase()===compName||
      (item.itemType==='db'&&/database|\bdb\b/i.test((c.type||c.role||'')+' '+(c.name||'')));
  });
  if(candidates.length===1)matched=candidates[0];
  else if(candidates.length>1)matched=candidates.find(function(item){
    return targetHost&&String(item.target||'').indexOf(targetHost)>=0;
  })||null;
  var scopeMatch=null,scope=[];
  try{scope=JSON.parse(localStorage.getItem('uat_scope')||'[]')||[];}catch(e4){}
  scopeMatch=scope.find(function(row){return targetHost&&String(row.target_ip||row.target||'').indexOf(targetHost)>=0;})||null;
  var sshUser=directUser||String((matched&&matched.sshUser)||(scopeMatch&&scopeMatch.ssh_user)||(R6P.bs&&(R6P.bs.sshUser||R6P.bs.ssh_user))||'').trim();
  var sshKeyPath=directKey||String((matched&&(matched.sshKeyPath||matched.sshKey))||(scopeMatch&&scopeMatch.ssh_key_path)||(R6P.bs&&(R6P.bs.sshKeyPath||R6P.bs.ssh_key_path||R6P.bs.sshKey))||'').trim();
  var dbEngine=String(c.dbEngine||c.databaseEngine||(matched&&matched.dbEngine)||(scopeMatch&&scopeMatch.db_engine)||'').trim();
  var dbPort=String(c.dbPort||c.databasePort||(matched&&matched.dbPort)||(scopeMatch&&scopeMatch.db_port)||'').trim();
  var explicitEndpoint=String(c.databaseEndpoint||c.database_endpoint||'').trim();
  var scheme=/postgre/i.test(dbEngine)?'postgresql':/maria/i.test(dbEngine)?'mariadb':/mysql/i.test(dbEngine)?'mysql':/mongo/i.test(dbEngine)?'mongodb':/redis/i.test(dbEngine)?'redis':'';
  if(!scheme){var sm=explicitEndpoint.match(/^([a-z][a-z0-9+.-]*):\/\//i);scheme=sm?sm[1].toLowerCase():'';}
  /* Ignore legacy databaseEndpoint hosts: executable endpoints use only the FLEX target. */
  var databaseEndpoint=scheme&&targetHost?scheme+'://'+targetHost+':'+(dbPort||({postgresql:'5432',mysql:'3306',mariadb:'3306',mongodb:'27017',redis:'6379'}[scheme])||''):'';
  return {sshUser:sshUser,sshKeyPath:sshKeyPath,sshConfigured:!!(sshUser&&sshKeyPath),databaseEngine:dbEngine,databaseEndpoint:databaseEndpoint,matchedInput:matched||scopeMatch};
};
window.r6pResolveComponentVm=function(c){
  c=c||{};var direct=c.sourceVmId||c.source_vm_id||c.vmId||c.vm_id||c.openstackServerId||c.serverId||c.flexVmId;
  if(direct)return{id:direct,name:c.sourceVmName||c.source_vm_name||c.vmName||c.vm_name||'',ip:c.sourceIp||c.source_ip||'',region:c.cloudRegion||c.cloud_region||''};
  var target=r6pComponentTarget(c),host='';try{host=new URL(target.indexOf('://')>=0?target:'ssh://'+target).hostname;}catch(e){host=target.replace(/^[a-z][a-z0-9+.-]*:\/\//i,'').split('/')[0].split(':')[0];}
  var rows=window._uatS1FlexVmRows||[],matches=rows.filter(function(row){return [row.public_ip,row.private_ip,row.ip].filter(Boolean).map(String).indexOf(String(host))>=0;});
  if(matches.length!==1)return{id:null,name:'',ip:host,region:'',mappingAmbiguous:matches.length>1};
  var row=matches[0];return{id:row.id||row.vm_id||row.server_id||row.uuid||null,name:row.name||'',ip:host,region:row.region||row.cloud_region||''};
};
window.r6pBusinessSystemsChanged=function(){
  R6P_BS_STORAGE_SIG='';
  if(typeof r6pLoadBiz==='function')r6pLoadBiz();
  r6pSyncSelectedBusinessSystem(true);
};
window.r6pInstallBusinessSystemAutoRefresh=function(){
  if(window._r6pBsAutoRefreshInstalled)return;
  window._r6pBsAutoRefreshInstalled=true;
  window.addEventListener('storage',function(e){
    if(e&&e.key==='uatS1_systems')r6pBusinessSystemsChanged();
    if(e&&e.key===R6P_SELECTED_BS_KEY)r6pSyncSelectedBusinessSystem(true);
  });
  window.addEventListener('uatS1:businessSystemsChanged',function(){r6pBusinessSystemsChanged();});
  setInterval(function(){r6pSyncSelectedBusinessSystem(false);},1200);
};
window.r6pInit=function(){
  r6pRenderProgress();r6pRenderStages();r6pInstallBusinessSystemAutoRefresh();
  setTimeout(r6pLoadBiz,350);setTimeout(r6pLoadCredCache,200);
  setTimeout(function(){Promise.resolve(r6pLoadCredsServer()).then(function(){setTimeout(r6pAutoRunStartupPreflight,150);},function(){setTimeout(r6pAutoRunStartupPreflight,150);});},250);
  r6pRenderClassifyChart();r6pRenderPipelineStepsTable();r6pRenderHybridDeltaChart();
  setTimeout(function(){r6pSyncSelectedBusinessSystem(true);r6pRenderContainerReadyForm();},400);
  /* A scan-interface change performs one deliberate reload. Reopen Stage 3
     only after the selected Business System and credential cache have had a
     chance to rehydrate; scan execution remains owned by the backend run. */
  var reopen=false;
  try{reopen=sessionStorage.getItem('r6p_scan_ui_reopen_stage')==='3';if(reopen)sessionStorage.removeItem('r6p_scan_ui_reopen_stage');}catch(e){}
  if(reopen)setTimeout(function(){r6pGoTo(3);},700);
};

/* Server-side credential persistence - survives incognito/browser reset/different browsers.
   localStorage stays as a fast local mirror; the server file is the source of truth. */
window.r6pSaveCredsServer=function(){
  var v=function(id){var el=document.getElementById(id);return el?el.value:'';};
  var payload={
    cloud:{authUrl:v('r6p-c-authurl'),authType:v('r6p-c-authtype'),username:v('r6p-c-username'),
      password:v('r6p-c-password'),credId:v('r6p-c-credid'),secret:v('r6p-c-secret'),
      proj:v('r6p-c-proj'),domain:v('r6p-c-domain'),region:v('r6p-c-region')},
    gitops:{repo:v('r6p-git-repo'),branch:v('r6p-git-branch'),auth:v('r6p-git-auth'),
      sshkey:v('r6p-git-sshkey'),localdir:v('r6p-git-localdir'),token:v('r6p-git-token')}
  };
  fetch('/api/r6/save-creds',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)}).catch(function(){});
};
window.r6pLoadCredsServer=function(){
  return fetch('/api/r6/load-creds').then(function(r){return r.json();}).then(function(d){
    if(!d||!d.ok||!d.data)return;
    var c=d.data.cloud||{},g=d.data.gitops||{};
    var set=function(id,val){if(!val)return;var el=document.getElementById(id);if(el&&!el.value)el.value=val;};
    set('r6p-c-authurl',c.authUrl);set('r6p-c-username',c.username);set('r6p-c-password',c.password);
    set('r6p-c-credid',c.credId);set('r6p-c-secret',c.secret);set('r6p-c-proj',c.proj);
    set('r6p-c-domain',c.domain);
    if(c.authType){var dt=document.getElementById('r6p-c-authtype');if(dt){dt.value=c.authType;r6pAuthTypeChange(c.authType);}}
    if(c.region){var rs=document.getElementById('r6p-c-region');if(rs)rs.value=c.region;}
    set('r6p-git-repo',g.repo);set('r6p-git-branch',g.branch);set('r6p-git-sshkey',g.sshkey);
    set('r6p-git-token',g.token);
    if(g.auth){var ga=document.getElementById('r6p-git-auth');if(ga){ga.value=g.auth;if(typeof r6pGitAuthToggle==='function')r6pGitAuthToggle();}}
    if(g.localdir&&typeof r6pLooksLikeGitDir==='function'&&r6pLooksLikeGitDir(g.localdir)){
      set('r6p-git-localdir',g.localdir);R6P.creds.opencenter.gitDir=g.localdir;
    } else if(typeof r6pAutoDetectGitDir==='function'){ r6pAutoDetectGitDir(); }
    if(typeof r6pRefreshCloudBadge==='function')setTimeout(r6pRefreshCloudBadge,0);
    var b=document.getElementById('r6p-git-badge');
    if(b&&g.repo){b.textContent='Configured';b.style.color='#15803d';}
  }).catch(function(){});
};
window.r6aceInit=window.r6pInit;

/* Steps 3-6 are required evidence-producing stages.  They used to be wrapped in
   one oversized "Inspect" card labelled "SKIP by Default"; the wrapper had no
   endpoint or artifact and incorrectly implied that live discovery was optional. */
var R6P_RESCAN_GROUP=[];
window.r6pRenderProgress=function(){
  var el=document.getElementById('r6p-progress-inner');if(!el)return;
  el.innerHTML=R6P_STEPS.map(function(s,i){
    var st=R6P.status[s.n]||'ns',isCur=R6P.current===s.n,cls=isCur?'current':st;
    return (i>0?'<span class="r6p-arrow">&gt;</span>':'')+'<span class="r6p-step '+cls+'" onclick="r6pGoTo('+s.n+')">'+s.n+'. '+s.label+'</span>';
  }).join('');
};

window.r6pRenderStages=function(){
  var el=document.getElementById('r6p-stages');if(!el)return;
  var guidelinesEl=document.getElementById('r6p-guidelines');
  var guidelines='<div class="r6p-stage" style="margin-bottom:14px;">'
    +'<div class="r6p-stage-hd" onclick="var b=document.getElementById(\'r6p-classify-chart-body\');if(b)b.classList.toggle(\'open\');var c=document.getElementById(\'r6p-classify-chevron\');if(c)c.style.transform=b&&b.classList.contains(\'open\')?\'rotate(90deg)\':\'\';">'
    +'<div class="r6p-stage-num">&#128202;</div>'
    +'<div class="r6p-stage-info"><div class="r6p-stage-title">Apps Containerization Guidelines</div><div class="r6p-stage-desc">Reference table: what state each component type usually has, and the default containerization decision. Component chips elsewhere auto-populate from this.</div></div>'
    +'<span id="r6p-classify-chevron" style="margin-left:10px;font-size:14px;color:#94a3b8;transition:transform .2s;">&#9654;</span>'
    +'</div>'
    +'<div class="r6p-stage-body" id="r6p-classify-chart-body"><div class="r6p-stage-body-inner" id="r6p-classify-chart-inner"></div></div>'
    +'</div>';
  if(guidelinesEl)guidelinesEl.innerHTML=guidelines;
  el.innerHTML=(guidelinesEl?'':guidelines)+R6P_STEPS.map(function(s){
    var st=R6P.status[s.n]||'ns',isCur=R6P.current===s.n;
    var bstyle=isCur?'background:#eff6ff;color:#0369a1;':st==='done'?'background:#dcfce7;color:#16a34a;':st==='warn'?'background:#fef3c7;color:#d97706;':st==='blocked'?'background:#fee2e2;color:#dc2626;':'background:#f1f5f9;color:#94a3b8;';
    var btxt=isCur?'Current':st==='done'?'Complete':st==='warn'?'Warning':st==='blocked'?'Blocked':'Not Started';
    var ccls='r6p-stage'+(isCur?' current':st!=='ns'?' '+st:'');
    var card='<div id="r6p-stage-'+s.n+'" class="'+ccls+'">'
      +'<div class="r6p-stage-hd" onclick="r6pToggle('+s.n+')">'
      +'<div class="r6p-stage-num">'+s.n+'</div>'
      +'<div class="r6p-stage-info"><div class="r6p-stage-title">'+s.title+'</div><div class="r6p-stage-desc">'+s.desc+'</div></div>'
      +'<span class="r6p-stage-badge" id="r6p-stage-badge-'+s.n+'" style="'+bstyle+'">'+btxt+'</span>'
      +'</div>'
      +'<div class="r6p-stage-body" id="r6p-body-'+s.n+'"><div class="r6p-stage-body-inner">'+r6pContent(s.n)+'</div></div>'
      +'</div>';
    if(s.n===1){
      card+='<div class="r6p-stage" style="margin-bottom:14px;">'
        +'<div class="r6p-stage-hd" onclick="var b=document.getElementById(\'r6p-container-ready-body\');if(b)b.classList.toggle(\'open\');var c=document.getElementById(\'r6p-container-ready-chevron\');if(c)c.style.transform=b&&b.classList.contains(\'open\')?\'rotate(90deg)\':\'\';;if(typeof r6pRenderContainerReadyForm===\'function\')r6pRenderContainerReadyForm();">'
        +'<div class="r6p-stage-num">&#128196;</div>'
        +'<div class="r6p-stage-info"><div class="r6p-stage-title">Apps Component Containers Mapping</div><div class="r6p-stage-desc">Per-component: category, endpoint, runtime, state, containerization decision, target Kubernetes resource, persistent data path, dependencies, health test, readiness and migration risk. Auto-populated from the selected Business System.</div></div>'
        +'<span id="r6p-container-ready-chevron" style="margin-left:10px;font-size:14px;color:#94a3b8;transition:transform .2s;">&#9654;</span>'
        +'</div>'
        +'<div class="r6p-stage-body" id="r6p-container-ready-body"><div class="r6p-stage-body-inner" id="r6p-container-ready-inner"></div></div>'
        +'</div>';
    }
    return card;
  }).join('');
};

window.r6pGoTo=function(n){
  R6P.current=n;
  R6P_STEPS.forEach(function(s){
    var b=document.getElementById('r6p-body-'+s.n),card=document.getElementById('r6p-stage-'+s.n);
    if(!b||!card)return;
    if(s.n===n){setTimeout(function(){b.classList.add('open');card.className='r6p-stage current';card.scrollIntoView({behavior:'smooth',block:'nearest'});},40);}
    else{b.classList.remove('open');var st=R6P.status[s.n]||'ns';card.className='r6p-stage'+(st!=='ns'?' '+st:'');}
  });
  r6pRenderProgress();
  if(n===1){setTimeout(r6pLoadBiz,200);}
  if(n===3){setTimeout(function(){r6pApplyScanUiVersion();r6pRestoreScanRun();},200);}
};
window.r6pToggle=function(n){
  var b=document.getElementById('r6p-body-'+n);
  var card=document.getElementById('r6p-stage-'+n);
  if(!b||!card)return;
  var willOpen=!b.classList.contains('open');
  if(willOpen){
    b.classList.add('open');
    R6P.current=n;
    var st=R6P.status[n]||'ns';
    card.className='r6p-stage current'+(st!=='ns'?' '+st:'');
    if(n===1)setTimeout(r6pLoadBiz,200);
  } else {
    b.classList.remove('open');
    var st2=R6P.status[n]||'ns';
    card.className='r6p-stage'+(st2!=='ns'?' '+st2:'');
  }
  r6pRenderProgress();
};

function r6pFoot(n,extra){var nextN=r6pAdjacentStep(n,1),complete=n===3?'r6pCompleteScanStage()':'r6pMarkDone('+n+')',next=n===3?'r6pCompleteScanStage()':'r6pGoTo('+nextN+')';return '<div class="r6p-stage-footer">'+(extra||'')+'<button class="r6p-btn success" onclick="'+complete+'">Mark Complete</button>'+(nextN!==undefined?'<button class="r6p-btn primary" onclick="'+next+'">Continue</button>':'')+'</div>';}
window.r6pScanStageCanContinue=function(){var run=R6P.structuredAppraisal,a=run&&run.appraisal;if(!run||!a){alert('Run or refresh the component scan before continuing.');return false;}if(run.status==='RUNNING'){alert('The scan is still running.');return false;}if(['BLOCKED','BLOCKED_INFRASTRUCTURE','BLOCKED_SECURITY','BLOCKED_APPLICATION','SCAN_FAILED','SCAN_ERROR','NOT_TESTED'].indexOf(a.finalVerdict)>=0||a.databaseReadiness==='BLOCKED'){alert('This appraisal has unresolved blockers. Review Failed Checks and retry the affected component before continuing.');return false;}if((a.finalVerdict==='READY_WITH_WARNINGS'||a.finalVerdict==='REVIEW_REQUIRED'||(a.systemWarnings||[]).length)&&R6P.appraisalReviewed!==true){alert('Review and acknowledge the appraisal warnings before continuing.');return false;}return true;};
window.r6pCompleteScanStage=function(){if(r6pScanStageCanContinue())r6pMarkDone(3);};

/* Real migration-mode decision engine (Stage 4-5): evaluates each component against
   name/type signals and, if available, the Steps 3-6 live scan output. */
window.r6pDecideMigrationMode=function(c){
  var name=(c.name||'').toLowerCase();
  var type=(c.type||c.role||'').toLowerCase();
  var isDb=type==='database'||type==='db'||/\b(db|database|sql|mysql|postgres|mongo|redis)\b/.test(name);
  var isWindows=/win|windows/.test(name)||/win|windows/.test(type);
  var scan=R6P.depScan&&R6P.depScan[c.name];
  var appFileCount=0;
  if(scan&&scan.rawLog){var m=scan.rawLog.split('\n').filter(function(l){return l.indexOf('/')===0;});appFileCount=m.length;}
  var siblingHasDb=(R6P.components||[]).some(function(x){var t=(x.type||x.role||'').toLowerCase();return x.name!==c.name&&(t==='database'||t==='db');});

  if(isWindows){
    return {name:c.name,workloadType:'Legacy Windows app',status:'COMPATIBILITY_CONTAINER_ONLY',
      reason:'Windows workloads are not cloud-native containerizable by this engine yet.',
      method:'Rehost VM first, containerize later only if possible'};
  }
  if(isDb){
    return {name:c.name,workloadType:'Database',status:'KEEP_ON_FLEX_VM_FOR_NOW',
      reason:'Stateful database - keep external, do not bake into a container image.',
      method:'Split app and DB, migrate DB separately (dump/restore or replication)'};
  }
  if(!scan){
    return {name:c.name,workloadType:'Unscanned application',status:'READY_WITH_EXTERNALIZATION',
      reason:'No live scan run yet (Steps 3-6) - assuming stateless until scanned.',
      method:'Containerize and deploy via OpenCenter GitOps (run live scan to confirm)'};
  }
  if(appFileCount>200){
    return {name:c.name,workloadType:'Complex monolith',status:'READY_WITH_EXTERNALIZATION',
      reason:appFileCount+' files found under app paths - large/complex codebase.',
      method:'Smart snapshot/app capture, then staged refactor'};
  }
  if(appFileCount>20){
    return {name:c.name,workloadType:'App with local files',status:'READY_WITH_EXTERNALIZATION',
      reason:appFileCount+' files found under app paths - needs persistent storage.',
      method:'Containerize + migrate data to PVC/object storage'};
  }
  if(siblingHasDb){
    return {name:c.name,workloadType:'App tier (DB is a sibling component)',status:'CLOUD_NATIVE_READY',
      reason:'Stateless app tier; database is handled as a separate component.',
      method:'Containerize and deploy via OpenCenter GitOps'};
  }
  return {name:c.name,workloadType:'Simple stateless web app',status:'CLOUD_NATIVE_READY',
    reason:appFileCount+' files found under app paths - lightweight, no local DB detected.',
    method:'Containerize and deploy via OpenCenter GitOps'};
};
var R6_TARGET_FORM_BADGE={
  CONTAINERIZED:['Containerize','#16a34a'],
  PARTIALLY_CONTAINERIZED:['Partially Containerize','#0d9488'],
  KUBERNETES_NATIVE:['Replace with Kubernetes','#7c3aed'],
  OPERATOR_MANAGED:['Deploy with Operator','#0369a1'],
  RETAINED_FLEX_VM:['Keep as VM','#1d4ed8'],
  REDEPLOYED_FLEX_VM:['Keep as VM','#1d4ed8'],
  EXTERNAL_SERVICE:['Keep as VM','#1d4ed8'],
  DATA_MIGRATION_REQUIRED:['Migrate Data Separately','#d97706'],
  MANUAL_REVIEW:['Unknown','#64748b'],
  BLOCKED:['Blocked','#dc2626'],
  EXCLUDED:['Excluded','#94a3b8']
};
window.r6pBadgeForTargetForm=function(form){
  return R6_TARGET_FORM_BADGE[form]||['Unknown','#64748b'];
};
/* Required gate before OpenCenter will deploy a component (Step 12 pre-flight) - keyed
   by the same 8 UI decision badges since the gate is about the decision, not the raw form. */
var R6_REQUIRED_GATE={
  'Containerize':'Image built, scanned and locally tested',
  'Partially Containerize':'Image built, scanned and locally tested; externalized state confirmed reachable',
  'Replace with Kubernetes':'Platform service available and configuration validated',
  'Deploy with Operator':'Operator installed and storage class confirmed',
  'Keep as VM':'DNS, network, credentials, TLS and health test validated',
  'Migrate Data Separately':'Data plan approved and rollback available',
  'Blocked':'Explicit manual override required',
  'Unknown':'Additional runtime inspection required before a gate can be assigned'
};
window.r6pRequiredGateFor=function(form){
  var badge=r6pBadgeForTargetForm(form)[0];
  return R6_REQUIRED_GATE[badge]||'Manual review required';
};
var R6_TARGET_FORMS=[['CONTAINERIZED','Converted into a tested Docker image and Kubernetes workload','Frontend, API, backend service'],['PARTIALLY_CONTAINERIZED','Application process becomes a container, but state stays outside','Reporting app with external reports'],['KUBERNETES_NATIVE','VM function is replaced by a native Kubernetes capability','Gateway API, CronJob, scheduler, platform monitoring'],['OPERATOR_MANAGED','Service is recreated through a Kubernetes operator','Redis, RabbitMQ, Kafka'],['RETAINED_FLEX_VM','Existing FLEX VM stays in service, unchanged','Oracle DB, legacy or commercial application'],['REDEPLOYED_FLEX_VM','Component remains a VM but can be recreated from its VM definition','Windows app, licensed software requiring a VM'],['EXTERNAL_SERVICE','Represented through a managed endpoint and logical service alias','Partner API, managed object storage, secrets manager'],['DATA_MIGRATION_REQUIRED','Persistent data is migrated independently of the application process','Upload volume, documents, object storage'],['MANUAL_REVIEW','Insufficient evidence for an automatic decision','Unknown legacy service'],['BLOCKED','Cannot currently be transformed or safely connected','Hardware-bound workload'],['EXCLUDED','Component is not required in the new system','Obsolete agent']];
window.r6pFormFromComponentDecision=function(decision){
  var d=String(decision||'').toLowerCase();
  if(!d)return '';
  if(/exclude/.test(d))return 'EXCLUDED';
  if(/block/.test(d))return 'BLOCKED';
  if(/redeploy.*vm/.test(d))return 'REDEPLOYED_FLEX_VM';
  if(/retain.*vm|keep external/.test(d))return 'RETAINED_FLEX_VM';
  if(/deploy with operator/.test(d))return 'OPERATOR_MANAGED';
  if(/replace with|convert to cronjob|use platform/.test(d))return 'KUBERNETES_NATIVE';
  if(/migrate separately/.test(d))return 'DATA_MIGRATION_REQUIRED';
  if(/external service|connect as external/.test(d))return 'EXTERNAL_SERVICE';
  if(/external database|after assessment|partially/.test(d))return 'PARTIALLY_CONTAINERIZED';
  if(/containerize/.test(d))return 'CONTAINERIZED';
  return 'MANUAL_REVIEW';
};
window.r6pFindComponentAppraisal=function(c){
  var list=R6P.structuredAppraisal&&R6P.structuredAppraisal.components||[];
  var id=c&&(c.id||c.componentId||c.component_id);
  var names=[c&&c.name].concat(c&&c.previousNames||[]).filter(Boolean);
  return list.find(function(x){return (id&&x.componentId===id)||names.indexOf(x.componentName)>=0;});
};
/* Real hybrid-transform decision engine (Stage 8 Transform table): assigns each real
   selected component one of the 11 target forms above, using its state/portability
   classification (r6pClassifyFor), name signals and the readiness engine's migration
   mode. Every decision is overridable per component and persisted in R6P.targetForms. */
window.r6pDecideTargetForm=function(c){
  var name=(c.name||'').toLowerCase();
  var savedForm=c.targetForm||r6pFormFromComponentDecision(c.containerizationDecision);
  if(savedForm)return {form:savedForm,reason:'Saved Stage 1 component decision: '+(c.containerizationDecision||savedForm)+'.'};
  var appraisal=r6pFindComponentAppraisal(c);
  if(appraisal){
    var mapped={STRONG_CONTAINER_CANDIDATE:'CONTAINERIZED',CANDIDATE_WITH_REMEDIATION:'PARTIALLY_CONTAINERIZED',PARTIAL_CONTAINERIZATION:'PARTIALLY_CONTAINERIZED',KUBERNETES_NATIVE_REPLACEMENT:'KUBERNETES_NATIVE',OPERATOR_MANAGED:'OPERATOR_MANAGED',DB_NATIVE_MIGRATION:'DATA_MIGRATION_REQUIRED',RETAIN_FLEX_VM:'RETAINED_FLEX_VM',REDEPLOY_FLEX_VM:'REDEPLOYED_FLEX_VM',EXTERNAL_SERVICE:'EXTERNAL_SERVICE',MANUAL_REVIEW:'MANUAL_REVIEW',BLOCKED:'BLOCKED'};
    if(mapped[appraisal.containerizationRecommendation])return {form:mapped[appraisal.containerizationRecommendation],reason:'Structured scan appraisal: '+appraisal.componentVerdict+'; readiness '+appraisal.containerReadinessScore+'%.'};
  }
  var cls=r6pClassifyForComponent(c)||{state:'Unknown / mixed',decision:''};
  var mig=r6pDecideMigrationMode(c);
  if(mig.status==='COMPATIBILITY_CONTAINER_ONLY'){
    return {form:'REDEPLOYED_FLEX_VM',reason:'Legacy/Windows workload - not containerizable yet; recreate as a VM from its FLEX definition.'};
  }
  /* Exact-name overrides checked before the broader substring regexes below, so a name
     that CONTAINS a keyword (e.g. "Database Proxy" contains "database") does not get
     misclassified by the keyword's generic rule - the proxy/app layer is stateless and
     containerizable even though the word "database" appears in its name. */
  if(/\bdatabase proxy\b/.test(name)){
    return {form:'CONTAINERIZED',reason:'Stateless proxy layer in front of the database - containerize; the database itself stays external.'};
  }
  if(/\bauth\b.*\bsso\b|\bsso\b.*\bauth\b|^auth\b/.test(name)){
    return {form:'PARTIALLY_CONTAINERIZED',reason:'Containerize the auth/SSO service; keep its user/session/identity store on an external database.'};
  }
  if(/core banking backend/.test(name)){
    return {form:'PARTIALLY_CONTAINERIZED',reason:'Containerize after assessment - core business logic, externalize database/sessions/files/secrets first.'};
  }
  if(/backup/.test(name)){
    return {form:'KUBERNETES_NATIVE',reason:'Platform capability - use the cluster backup service (e.g. Velero) with external backup storage rather than a custom container.'};
  }
  if(/reporting app/.test(name)){
    return {form:'CONTAINERIZED',reason:'Containerize the reporting application; store generated reports externally, not in the image.'};
  }
  if(/database|(^|[^a-z])db([^a-z]|$)|mysql|postgres|mongo|oracle|mssql|nosql/.test(name)){
    return {form:'RETAINED_FLEX_VM',reason:'Stateful database - keep the existing FLEX VM in service; do not bake into a container image.'};
  }
  if(/legacy|erp|commercial|mainframe/.test(name)){
    return {form:'RETAINED_FLEX_VM',reason:'Legacy or commercial/licensed application - keep the existing FLEX VM in service.'};
  }
  if(/redis|rabbitmq|kafka|cache|queue|session store|event stream|search engine/.test(name)){
    return {form:'OPERATOR_MANAGED',reason:'Stateful platform service - recreate through a Kubernetes operator instead of a plain container.'};
  }
  if(/gateway|load balancer|\bscheduler\b/.test(name)){
    return {form:'KUBERNETES_NATIVE',reason:'VM function has a native Kubernetes equivalent (Gateway API, CronJob, etc).'};
  }
  if(/monitoring|tracing|metrics exporter|log processor|\blogging\b/.test(name)){
    return {form:'KUBERNETES_NATIVE',reason:'Platform capability - replace with the cluster-native equivalent (Prometheus/Grafana/OTel) rather than migrating the VM.'};
  }
  if(/object storage|file storage|upload|document/.test(name)){
    return {form:'DATA_MIGRATION_REQUIRED',reason:'Persistent files/objects must be migrated independently of the application process.'};
  }
  if(/secrets manager/.test(name)){
    return {form:'EXTERNAL_SERVICE',reason:'Represent through a managed endpoint and Secret reference rather than redeploying.'};
  }
  if(cls.state==='Stateless'){
    if(mig.workloadType==='Complex monolith'){
      return {form:'PARTIALLY_CONTAINERIZED',reason:'Large/complex codebase - containerize the process but keep verifying externalized state first.'};
    }
    return {form:'CONTAINERIZED',reason:'Stateless component - safe to containerize and run as a Kubernetes Deployment.'};
  }
  if(cls.state==='Stateful'){
    return {form:'DATA_MIGRATION_REQUIRED',reason:'Stateful component without a specific operator match - plan an independent data migration.'};
  }
  return {form:'MANUAL_REVIEW',reason:'Insufficient evidence for an automatic decision - review manually before assigning a target form.'};
};
window.r6pDecisionLabelFor=function(c,form){
  if(c&&c.containerizationDecision)return c.containerizationDecision;
  var n=String(c&&c.name||'').toLowerCase();
  if(/gateway/.test(n))return 'Replace with Gateway API';
  if(/auth.*sso|sso.*auth/.test(n))return 'Containerize with external database';
  if(/core banking backend/.test(n))return 'Containerize after assessment';
  if(form==='CONTAINERIZED')return 'Containerize';
  if(form==='PARTIALLY_CONTAINERIZED')return 'Partially containerize';
  if(form==='OPERATOR_MANAGED')return 'Deploy with operator';
  if(form==='RETAINED_FLEX_VM')return /database/.test(n)?'Keep external initially':'Retain FLEX VM';
  if(form==='REDEPLOYED_FLEX_VM')return 'Redeploy FLEX VM';
  if(form==='KUBERNETES_NATIVE')return 'Replace with Kubernetes capability';
  if(form==='DATA_MIGRATION_REQUIRED')return 'Migrate separately';
  if(form==='EXTERNAL_SERVICE')return 'External service';
  if(form==='BLOCKED')return 'Block';
  if(form==='EXCLUDED')return 'Exclude';
  return 'Manual review';
};
window.r6pPersistComponentFields=function(name,fields){
  var component=(R6P.components||[]).find(function(c){return c.name===name;});
  if(component)Object.assign(component,fields);
  try{
    var systems=JSON.parse(localStorage.getItem('uatS1_systems')||'[]');
    var system=systems.find(function(s){return R6P.bs&&s.id===R6P.bs.id;});
    var saved=system&&(system.components||[]).find(function(c){return c.name===name;});
    if(saved){Object.assign(saved,fields);localStorage.setItem('uatS1_systems',JSON.stringify(systems));R6P_BS_STORAGE_SIG=JSON.stringify(systems);}
  }catch(e){}
};
window.r6pSetTargetForm=function(name,val){
  R6P.targetForms=R6P.targetForms||{};
  R6P.targetForms[name]=val;
  var component=(R6P.components||[]).find(function(c){return c.name===name;})||{name:name};
  r6pPersistComponentFields(name,{targetForm:val,containerizationDecision:r6pDecisionLabelFor({name:component.name},val)});
  var b=document.getElementById('r6p-tf-badge-'+btoa(unescape(encodeURIComponent(name))).replace(/[^a-zA-Z0-9]/g,''));
  if(typeof r6pRenderContainerReadyForm==='function')r6pRenderContainerReadyForm();
};
window.r6pSetStartCommand=function(name,val){
  R6P.startCmdOverride=R6P.startCmdOverride||{};
  R6P.startCmdOverride[name]=val;
};
/* State/portability override (Step 7 Classify table) - takes priority over the static
   reference classification and also feeds Step 8's Transform decision engine, so an
   engineer's override in Classify actually changes the downstream target-form default. */
window.r6pClassifyForComponent=function(c){
  var name=c&&c.name||'';
  var base=r6pClassifyFor(name);
  if(R6P.classifyOverride&&R6P.classifyOverride[name]){
    return {state:R6P.classifyOverride[name],decision:base.decision};
  }
  var appraisal=r6pFindComponentAppraisal(c);
  if(appraisal){
    var state={STATELESS:'Stateless',STATEFUL:'Stateful',MIXED:'Unknown / mixed',UNKNOWN:'Unknown / mixed'}[appraisal.stateClassification]||'Unknown / mixed';
    return {state:state,decision:appraisal.containerizationRecommendation+' ('+appraisal.containerReadinessScore+'% readiness)'};
  }
  if(c&&['Stateless','Stateful','Unknown / mixed'].indexOf(c.state)>=0){
    return {state:c.state,decision:c.containerizationDecision||base.decision};
  }
  return base;
};
window.r6pSetClassifyOverride=function(name,val){
  R6P.classifyOverride=R6P.classifyOverride||{};
  R6P.classifyOverride[name]=val;
  r6pPersistComponentFields(name,{state:val});
  if(typeof r6pRenderContainerReadyForm==='function')r6pRenderContainerReadyForm();
};
/* Per-component lifecycle status. The pipeline currently checkpoints at the
   business-system level (one Mark Complete/Approve per step, not per component),
   so this derives a real, honest stage from those actual step-completion flags
   rather than inventing untracked per-component granularity. Kept-external
   components (Keep as VM badge) follow the short KEEP_EXTERNAL path instead
   of the container build path. */
window.r6pLifecycleFor=function(c){
  var saved=(R6P.targetForms&&R6P.targetForms[c.name])||r6pDecideTargetForm(c).form;
  var badge=r6pBadgeForTargetForm(saved)[0];
  var isExternalPath=(badge==='Keep as VM'||saved==='EXTERNAL_SERVICE'||saved==='EXCLUDED');
  var st=R6P.status||{};
  if(st[13]==='done')return 'CUTOVER_VALIDATED';
  if(isExternalPath){
    if(st[12]==='done')return 'BACKUP_VALIDATED';
    if(st[8]==='done')return 'CONNECTIVITY_VALIDATED';
    if(R6P.targetForms&&R6P.targetForms[c.name])return 'KEEP_EXTERNAL';
    return 'CLASSIFIED';
  }
  if(st[12]==='done')return 'STAGING_DEPLOYED';
  if(st[11]==='done'||R6P.bundle||R6P._realBundle)return 'IMAGE_GENERATED';
  if(st[9]==='done')return 'IMAGE_GENERATED';
  if(st[8]==='done')return 'DECISION_APPROVED';
  if(R6P.targetForms&&R6P.targetForms[c.name])return 'DECISION_APPROVED';
  if(st[7]==='done'||R6P.classifyOverride&&R6P.classifyOverride[c.name])return 'CLASSIFIED';
  return 'DISCOVERED';
};
/* Container-Ready Business Apps System Form (R6 only - does NOT touch the shared
   Add Business System modal used by Migration Log/Stage 2). Real per-component
   12-field profile, derived entirely from real component data (c.name/c.type/
   c.src/c.tgt/c.path, exactly the fields _uatS1SaveSystem actually saves) plus the
   existing real classify/transform/readiness engines. Auto-refreshes whenever a
   Business System is selected or a Classify/Transform override changes. */
window.r6pGuessRuntime=function(c){
  if(c&&c.runtime)return c.runtime;
  var n=(c.name||'').toLowerCase(), t=(c.type||'').toLowerCase();
  var hay=n+' '+t;
  if(/mysql/.test(hay))return 'MySQL';
  if(/postgres/.test(hay))return 'PostgreSQL';
  if(/mongo/.test(hay))return 'MongoDB';
  if(/redis/.test(hay))return 'Redis';
  if(/rabbitmq/.test(hay))return 'RabbitMQ';
  if(/kafka|event stream/.test(hay))return 'Kafka';
  if(/oracle/.test(hay))return 'Oracle Database';
  if(/nosql/.test(hay))return 'NoSQL Database (product TBD)';
  if(/windows/.test(hay))return 'Windows Server application';
  if(/frontend|web /.test(hay))return 'Node.js/Nginx (typical) - inspect to confirm';
  if(/gateway/.test(hay))return 'API Gateway / Envoy (typical) - inspect to confirm';
  if(/database|\bdb\b/.test(hay))return 'Relational database (product TBD)';
  if(/cache/.test(hay))return 'Cache service (product TBD)';
  if(/queue/.test(hay))return 'Message queue (product TBD)';
  if(/search/.test(hay))return 'Search engine (product TBD)';
  if(/object storage|file storage|upload/.test(hay))return 'Object/file storage service';
  var scan=R6P.depScan&&R6P.depScan[c.name];
  if(scan)return 'Detected from live scan - see Step 3';
  return 'Unknown - run Live Scan (Step 3) to confirm';
};
var R6_K8S_RESOURCE_FOR_FORM={
  CONTAINERIZED:'Deployment + Service',
  PARTIALLY_CONTAINERIZED:'Deployment + Service (state externalized to PVC/DB/ConfigMap)',
  KUBERNETES_NATIVE:'Native Kubernetes capability (Gateway API, CronJob, etc)',
  OPERATOR_MANAGED:'Custom Resource via Operator',
  RETAINED_FLEX_VM:'None in-cluster - Service alias + EndpointSlice to the FLEX VM',
  REDEPLOYED_FLEX_VM:'None in-cluster - Service alias + EndpointSlice to the redeployed VM',
  EXTERNAL_SERVICE:'ExternalName Service',
  DATA_MIGRATION_REQUIRED:'PVC or object storage (data only, no compute resource)',
  MANUAL_REVIEW:'TBD - manual review required',
  BLOCKED:'None - blocked',
  EXCLUDED:'None - excluded from target system'
};
window.r6pTargetK8sResourceFor=function(form){
  return R6_K8S_RESOURCE_FOR_FORM[form]||'TBD';
};
window.r6pPersistentPathFor=function(c){
  if(c&&c.persistentDataPath)return c.persistentDataPath;
  var hay=((c.name||'')+' '+(c.type||'')).toLowerCase();
  if(/mysql/.test(hay))return '/var/lib/mysql';
  if(/postgres/.test(hay))return '/var/lib/postgresql/data';
  if(/mongo/.test(hay))return '/data/db';
  if(/database|\bdb\b/.test(hay))return '/var/lib/ (database engine data directory)';
  if(/redis|cache/.test(hay))return 'None required - disposable, rebuilds on restart';
  if(/rabbitmq|queue/.test(hay))return '/var/lib/rabbitmq';
  if(/kafka|event stream/.test(hay))return '/var/lib/kafka';
  if(/object storage|upload|file storage|document/.test(hay))return '/srv/ (move to object storage/PVC)';
  if(/frontend/.test(hay))return 'None - stateless';
  if(/api|backend|gateway|worker|service/.test(hay))return 'None expected - verify no local writes during Step 3 scan';
  return 'Unknown - run Live Scan (Step 3) to confirm';
};
var R6_MIGRATION_RISK_FOR_STATUS={
  CLOUD_NATIVE_READY:'Low',
  READY_WITH_EXTERNALIZATION:'Medium - requires externalizing local state first',
  KEEP_ON_FLEX_VM_FOR_NOW:'Medium - stateful, requires a planned data migration',
  COMPATIBILITY_CONTAINER_ONLY:'High - legacy/Windows workload, not yet containerizable'
};
window.r6pMigrationRiskFor=function(status){
  return R6_MIGRATION_RISK_FOR_STATUS[status]||'Unknown';
};
window.r6pDependenciesFor=function(c){
  if(c&&c.dependencies)return c.dependencies;
  var scan=R6P.depScan&&R6P.depScan[c.name];
  if(scan&&scan.rawLog){
    var ports=(scan.rawLog.match(/LISTEN\s+\S+:(\d+)/g)||[]).slice(0,5).join(', ');
    if(ports)return 'Detected from live scan - listening ports: '+ports;
  }
  var siblings=(R6P.components||[]).filter(function(x){return x.name!==c.name;}).map(function(x){return x.name;});
  if(!siblings.length)return 'No other components in this Business System';
  return 'Not yet scanned - other components in this system: '+siblings.join(', ');
};
window.r6pComponentProfile=function(c){
  var cls=r6pClassifyForComponent(c);
  var mig=r6pDecideMigrationMode(c);
  var saved=(R6P.targetForms&&R6P.targetForms[c.name])||c.targetForm||r6pDecideTargetForm(c).form;
  var tf=r6pDecideTargetForm(c);
  return {
    name:c.name||'(unnamed component)',
    category:(c.type||'').replace(/^Component Type:\s*/i,'')||'Application',
    endpoint:c.tgt||'Not set - fill in Target IP/URL in Step 1 Inspect',
    runtime:r6pGuessRuntime(c),
    state:cls.state,
    decision:r6pDecisionLabelFor(c,saved),
    targetK8sResource:c.targetRuntimeResource||r6pTargetK8sResourceFor(saved),
    persistentPath:r6pPersistentPathFor(c),
    dependencies:r6pDependenciesFor(c),
    healthTest:c.path||'Not set - fill in Health/Test Path in Step 1 Inspect',
    readiness:mig.status,
    migrationRisk:r6pMigrationRiskFor(mig.status),
    recommendedAction:tf.reason,
    targetForm:saved
  };
};
window.r6pFilterContainerReady=function(filter){
  var host=document.getElementById('r6p-container-ready-inner')||document.getElementById('r6p-container-ready-body');if(!host)return;
  R6P._containerReadyFilter=filter;
  host.querySelectorAll('.r6p-cr-card').forEach(function(card){
    var show=(filter==='all')
      ||(card.getAttribute('data-badge')===filter)
      ||(card.getAttribute('data-state')===filter)
      ||(filter==='highrisk'&&card.getAttribute('data-risk')==='High');
    card.style.display=show?'':'none';
  });
  host.querySelectorAll('.r6p-cr-filter-btn').forEach(function(btn){
    btn.style.background=(btn.getAttribute('data-filter')===filter)?'#0369a1':'#f1f5f9';
    btn.style.color=(btn.getAttribute('data-filter')===filter)?'#fff':'#334155';
  });
};
window.r6pRenderContainerReadyForm=function(){
  var host=document.getElementById('r6p-container-ready-inner')||document.getElementById('r6p-container-ready-body');if(!host)return;
  var comps=R6P.components||[];
  if(!comps.length){host.innerHTML='<div class="r6p-warn-box">No Business System selected yet. Select one in Step 1 to auto-populate this form.</div>';return;}
  var stColor={'Stateless':'#16a34a','Stateful':'#dc2626','Unknown / mixed':'#d97706'};
  var riskColor=function(r){return /Low/.test(r)?'#16a34a':/High/.test(r)?'#dc2626':/Medium/.test(r)?'#d97706':'#64748b';};
  var profiles=comps.map(function(c){return {c:c,p:r6pComponentProfile(c)};});
  var badgeCounts={};
  profiles.forEach(function(x){var b=r6pBadgeForTargetForm(x.p.targetForm)[0];badgeCounts[b]=(badgeCounts[b]||0)+1;});
  var riskHighCount=profiles.filter(function(x){return /High/.test(x.p.migrationRisk);}).length;
  var filter=R6P._containerReadyFilter||'all';
  var filterDefs=[['all','All'],['Stateless','Stateless'],['Stateful','Stateful'],['Unknown / mixed','Unknown'],
    ['Containerize','Containerize'],['Replace with Kubernetes','Kubernetes-native'],['Deploy with Operator','Operator-managed'],
    ['Keep as VM','Retained/Redeployed VM'],['Migrate Data Separately','External/Data-migration'],['Blocked','Blocked'],['highrisk','High risk']];
  var filterBtns=filterDefs.map(function(f){
    return '<button class="r6p-cr-filter-btn" data-filter="'+f[0]+'" onclick="r6pFilterContainerReady(\''+f[0]+'\')" style="background:'+(filter===f[0]?'#0369a1':'#f1f5f9')+';color:'+(filter===f[0]?'#fff':'#334155')+';border:none;border-radius:999px;padding:4px 12px;font-size:11px;font-weight:700;cursor:pointer;margin:2px;">'+f[1]+'</button>';
  }).join('');
  var counterDefs=[['Components',comps.length,'#0f172a'],['Containerized',badgeCounts['Containerize']||0,'#16a34a'],
    ['Operator-managed',badgeCounts['Deploy with Operator']||0,'#0369a1'],['Kept as VM',badgeCounts['Keep as VM']||0,'#1d4ed8'],
    ['Data migration',badgeCounts['Migrate Data Separately']||0,'#d97706'],['High risk',riskHighCount,'#dc2626']];
  var counters=counterDefs.map(function(c){
    return '<div style="background:#f8fafc;border:1px solid #e2e8f0;border-radius:8px;padding:8px 12px;text-align:center;min-width:90px;"><div style="font-size:18px;font-weight:900;color:'+c[2]+';">'+c[1]+'</div><div style="font-size:9px;font-weight:700;color:#64748b;text-transform:uppercase;">'+c[0]+'</div></div>';
  }).join('');
  host.innerHTML='<div style="font-size:12px;color:#64748b;margin-bottom:10px;">Auto-populated for every component in <strong>'+((R6P.bs&&R6P.bs.name)||'the selected system')+'</strong>. Distinguishes application processes that should become containers from stateful infrastructure that should be rebuilt, operator-managed, externally retained, or migrated separately.</div>'
  +'<div style="display:flex;flex-wrap:wrap;gap:8px;margin-bottom:10px;">'+counters+'</div>'
  +'<div style="margin-bottom:14px;">'+filterBtns+'</div>'
  +'<div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(340px,1fr));gap:12px;">'
  +profiles.map(function(x){
    var c=x.c,p=x.p;
    var badge=r6pBadgeForTargetForm(p.targetForm);
    var dot=stColor[p.state]||'#64748b';
    var rc=riskColor(p.migrationRisk);
    var riskLevel=/Low/.test(p.migrationRisk)?'Low':/High/.test(p.migrationRisk)?'High':/Medium/.test(p.migrationRisk)?'Medium':'Unknown';
    var row=function(label,val){return '<div style="display:flex;justify-content:space-between;gap:10px;padding:4px 0;border-bottom:1px solid #f1f5f9;font-size:11px;"><span style="color:#94a3b8;font-weight:700;flex-shrink:0;">'+label+'</span><span style="color:#334155;text-align:right;">'+val+'</span></div>';};
    return '<div class="r6p-cr-card" data-badge="'+badge[0]+'" data-state="'+p.state+'" data-risk="'+riskLevel+'" style="border:1.5px solid #e2e8f0;border-radius:10px;padding:14px;background:#fff;'+(filter==='all'?'':'display:none;')+'">'
      +'<div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px;"><div style="font-weight:800;font-size:13px;color:#0f172a;">'+p.name+'</div><span style="background:'+badge[1]+'22;color:'+badge[1]+';padding:2px 8px;border-radius:999px;font-size:10px;font-weight:700;">'+badge[0]+'</span></div>'
      +row('Component category',p.category)
      +row('Current FLEX endpoint','<span style="font-family:monospace;">'+p.endpoint+'</span>')
      +row('Runtime or product',p.runtime)
      +row('State','<span style="background:'+dot+'22;color:'+dot+';padding:1px 7px;border-radius:999px;font-weight:700;">'+p.state+'</span>')
      +row('Containerization decision',p.decision)
      +row('Target Runtime Resource',p.targetK8sResource)
      +row('Persistent data path',p.persistentPath)
      +row('Dependencies',p.dependencies)
      +row('Health test','<span style="font-family:monospace;">'+p.healthTest+'</span>')
      +row('Readiness status',p.readiness.replace(/_/g,' '))
      +row('Migration risk','<span style="color:'+rc+';font-weight:700;">'+p.migrationRisk+'</span>')
      +row('Recommended action',p.recommendedAction)
      +'</div>';
  }).join('')
  +'</div>';
};
function r6pCmd(id,cmd){var cid='r6p-cmd-'+id,oid='r6p-out-'+id;return '<div class="r6p-cmd-box" id="'+cid+'">'+cmd.replace(/</g,'&lt;').replace(/>/g,'&gt;')+'</div><div style="display:flex;gap:5px;margin-bottom:8px;"><button onclick="navigator.clipboard&&navigator.clipboard.writeText(document.getElementById(\''+cid+'\').textContent)" style="background:#f1f5f9;color:#475569;border:1px solid #e2e8f0;border-radius:4px;padding:3px 10px;font-size:10px;cursor:pointer;">Copy</button><button onclick="r6pRunCmd(\''+cid+'\',\''+oid+'\')" style="background:#eff6ff;color:#0369a1;border:1px solid #bfdbfe;border-radius:4px;padding:3px 10px;font-size:10px;font-weight:700;cursor:pointer;">Run</button><button onclick="var e=document.getElementById(\''+oid+'\');e.style.display=e.style.display===\'none\'?\'block\':\'none\'" style="background:#f1f5f9;color:#64748b;border:1px solid #e2e8f0;border-radius:4px;padding:3px 10px;font-size:10px;cursor:pointer;">Log</button></div><div id="'+oid+'" class="r6p-terminal" style="display:none;">$ waiting...</div>';}

window.r6pHandoverSection=function(){
  var LEFT_CHECKS=[['R6 BUNDLE & KUBERNETES','#0369a1',[
    'Toolchain','Bundle Completeness','Image Manifest','YAML Parse',
    'Kustomize Staging','Kustomize Production','Namespace + PSS','RBAC / SecCtx',
    'NetworkPolicies','Storage / PVCs','Flux Kustomization','Stage 12 Gate','Rollback Runbook'
  ]]];
  var RIGHT_CHECKS=[['TARGET OPENCENTER ENVIRONMENT','#0369a1',[
    'Registry Access','Kubernetes Access','StorageClass','Gateway API',
    'Cert Manager','Flux Operator','Monitoring Stack','Backup Capability'
  ]],['HYBRID VM','#b45309',[
    'VM Identity','EndpointSlice','SG Intent','Validation Jobs'
  ]]];
  function checkRows(items){return items.map(function(label){return '<div style="display:flex;justify-content:space-between;align-items:center;padding:5px 0;border-bottom:1px solid #f1f5f9;">'+'<span style="font-size:12px;color:#334155;">'+label+'</span>'+'<span class="r6h-badge r6h-badge-pending" data-check="'+label+'">Pending</span>'+'</div>';}).join('');}
  var leftHtml=LEFT_CHECKS.map(function(g){return '<div style="font-size:11px;font-weight:800;color:'+g[1]+';text-transform:uppercase;letter-spacing:1px;margin:10px 0 6px;">'+g[0]+'</div>'+checkRows(g[2]);}).join('');
  var rightHtml=RIGHT_CHECKS.map(function(g){return '<div style="font-size:11px;font-weight:800;color:'+g[1]+';text-transform:uppercase;letter-spacing:1px;margin:10px 0 6px;">'+g[0]+'</div>'+checkRows(g[2]);}).join('');
  return '<div id="r6p-handover-section" style="margin-top:24px;border:2px solid #1e3a5f;border-radius:14px;overflow:hidden;background:#0f172a;">'
    +'<div style="background:linear-gradient(135deg,#0f172a 0%,#1e3a5f 100%);padding:16px 20px;display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:10px;">'
    +'<div><div id="r6p-handover-status-badge" style="display:inline-block;background:#334155;color:#94a3b8;font-size:10px;font-weight:700;padding:2px 10px;border-radius:4px;letter-spacing:1px;margin-bottom:6px;">NOT RUN</div>'
    +'<div style="display:flex;align-items:center;gap:8px;"><span style="font-size:18px;">&#9989;</span><div><div style="font-size:16px;font-weight:900;color:#f8fafc;">Final R6 &rarr; OpenCenter Handover Readiness</div>'
    +'<div style="font-size:11px;color:#94a3b8;margin-top:2px;">Verify images, Kubernetes resources, GitOps bundle, hybrid VM connections, platform prerequisites and rollback readiness before releasing to OpenCenter.</div></div></div></div>'
    +'<div style="display:flex;gap:8px;flex-wrap:wrap;align-items:center;">'
    +'<button onclick="r6pRunHandoverCheck()" style="background:#dc2626;color:#fff;border:none;border-radius:6px;padding:10px 18px;font-size:13px;font-weight:800;cursor:pointer;">&#9654; Run Handover Check</button>'
    +'<button onclick="r6pStopHandover()" style="background:#1e293b;color:#f87171;border:1px solid #f87171;border-radius:6px;padding:8px 12px;font-size:12px;font-weight:700;cursor:pointer;">&#9632; Stop</button>'
    +'<button onclick="r6pRetryHandover()" style="background:#1e293b;color:#60a5fa;border:1px solid #60a5fa;border-radius:6px;padding:8px 12px;font-size:12px;font-weight:700;cursor:pointer;">&#8635; Retry</button>'
    +'<button onclick="r6pExportHandover()" style="background:#1e293b;color:#94a3b8;border:1px solid #475569;border-radius:6px;padding:8px 12px;font-size:12px;cursor:pointer;">&#11015; Export</button>'
    +'</div></div>'
    +'<div style="display:grid;grid-template-columns:repeat(7,1fr);gap:1px;background:#1e3a5f;">'
    +['SCORE','PASSED','WARNINGS','BLOCKED','N/A','TOTAL','DURATION'].map(function(l,i){var colors=['#60a5fa','#4ade80','#fbbf24','#f87171','#94a3b8','#e2e8f0','#a78bfa'];return '<div style="background:#0f172a;padding:12px 8px;text-align:center;"><div style="font-size:18px;font-weight:900;color:'+colors[i]+';border-bottom:2px solid '+colors[i]+';padding-bottom:4px;margin-bottom:4px;" id="r6p-hsc-'+l.toLowerCase().replace('/','').replace(' ','')+'">&mdash;</div><div style="font-size:9px;font-weight:700;color:#64748b;text-transform:uppercase;letter-spacing:1px;">'+l+'</div></div>';}).join('')
    +'</div>'
    +'<div style="display:grid;grid-template-columns:1fr 260px 1fr;gap:0;background:#1e293b;">'
    +'<div style="padding:14px 16px;background:#f8fafc;">'+leftHtml+'</div>'
    +'<div style="background:#1e293b;display:flex;flex-direction:column;align-items:center;padding:16px 8px;gap:10px;">'
    +'<div style="font-size:9px;font-weight:800;color:#60a5fa;text-transform:uppercase;letter-spacing:2px;margin-bottom:4px;">OpenCenter Live Preview</div>'
    +'<div style="width:169px;height:338px;background:#fff;border:8px solid #1e293b;border-radius:28px;outline:4px solid #334155;overflow:hidden;box-shadow:0 0 0 2px #0f172a,0 8px 32px rgba(0,0,0,.6);" id="r6p-handover-phone"><div style="height:100%;display:flex;align-items:center;justify-content:center;background:#0f172a;color:#475569;font-size:11px;text-align:center;padding:8px;">OpenCenter<br>preview<br>will load here</div></div>'
    +'<div style="background:#0f172a;border-radius:8px;padding:8px 10px;width:220px;">'
    +'<div style="font-size:10px;color:#64748b;margin-bottom:2px;">Host <span id="r6p-h-host" style="color:#e2e8f0;font-weight:700;">&mdash;</span></div>'
    +'<div style="font-size:10px;color:#64748b;margin-bottom:2px;">HTTP <span id="r6p-h-http" style="color:#e2e8f0;font-weight:700;">&mdash;</span></div>'
    +'<div style="font-size:10px;color:#64748b;margin-bottom:6px;">Latency <span id="r6p-h-lat" style="color:#e2e8f0;font-weight:700;">&mdash;</span></div>'
    +'<div style="display:flex;gap:4px;margin-bottom:6px;">'
    +'<button onclick="r6pHandoverLoad()" style="background:#16a34a;color:#fff;border:none;border-radius:4px;padding:4px 8px;font-size:10px;cursor:pointer;">Load</button>'
    +'<button onclick="r6pHandoverHealth()" style="background:#dc2626;color:#fff;border:none;border-radius:4px;padding:4px 8px;font-size:10px;cursor:pointer;">Health</button>'
    +'<button onclick="r6pHandoverReady()" style="background:#d97706;color:#fff;border:none;border-radius:4px;padding:4px 8px;font-size:10px;cursor:pointer;">Ready</button>'
    +'<button onclick="r6pHandoverLogin()" style="background:#7c3aed;color:#fff;border:none;border-radius:4px;padding:4px 8px;font-size:10px;cursor:pointer;">Login</button>'
    +'</div>'
    +'<input id="r6p-h-hostport" placeholder="host:port" style="width:100%;box-sizing:border-box;background:#1e293b;border:1px solid #334155;border-radius:4px;padding:5px 8px;font-size:11px;color:#e2e8f0;">'
    +'</div></div>'
    +'<div style="padding:14px 16px;background:#f8fafc;">'+rightHtml+'</div>'
    +'</div>'
    +'<div style="background:#fff;padding:10px 14px;display:flex;gap:6px;align-items:center;flex-wrap:wrap;border-top:1px solid #e2e8f0;">'
    +'<button onclick="r6pHFilter(\'all\')" style="background:#334155;color:#fff;border:none;border-radius:4px;padding:4px 10px;font-size:11px;cursor:pointer;">All</button>'
    +'<button onclick="r6pHFilter(\'blocked\')" style="background:#dc2626;color:#fff;border:none;border-radius:4px;padding:4px 10px;font-size:11px;cursor:pointer;">&#128308; Blocked</button>'
    +'<button onclick="r6pHFilter(\'warning\')" style="background:#d97706;color:#fff;border:none;border-radius:4px;padding:4px 10px;font-size:11px;cursor:pointer;">&#9651; Warning</button>'
    +'<button onclick="r6pHFilter(\'pass\')" style="background:#16a34a;color:#fff;border:none;border-radius:4px;padding:4px 10px;font-size:11px;cursor:pointer;">&#10003; Pass</button>'
    +'<button onclick="r6pHFilter(\'pending\')" style="background:#f1f5f9;color:#475569;border:1px solid #e2e8f0;border-radius:4px;padding:4px 10px;font-size:11px;cursor:pointer;">Pending</button>'
    +'<input id="r6p-h-search" placeholder="Search..." oninput="r6pHSearch(this.value)" style="margin-left:auto;padding:4px 10px;border:1px solid #e2e8f0;border-radius:4px;font-size:11px;width:160px;">'
    +'</div>'
    +'<div style="background:#fff;overflow-x:auto;">'
    +'<table class="r6p-table" id="r6p-handover-table"><thead><tr><th>Status</th><th>ID</th><th>Checkpoint</th><th>Result</th><th>Blocking</th><th>Duration</th><th>Action</th></tr></thead>'
    +'<tbody id="r6p-handover-tbody"><tr><td colspan="7" style="text-align:center;color:#94a3b8;padding:20px;">Click <strong>Run Handover Check</strong> to verify the R6 bundle</td></tr></tbody>'
    +'</table></div>'
    +'</div>'
    +'<style>.r6h-badge{padding:2px 8px;border-radius:999px;font-size:10px;font-weight:700;}.r6h-badge-pending{background:#f1f5f9;color:#94a3b8;}.r6h-badge-pass{background:#dcfce7;color:#16a34a;}.r6h-badge-blocked{background:#fee2e2;color:#dc2626;}.r6h-badge-warning{background:#fef3c7;color:#d97706;}</style>';
};
window.r6pRunHandoverCheck=function(){
  var btn=document.querySelector('#r6p-handover-section button');
  var badge=document.getElementById('r6p-handover-status-badge');
  if(badge){badge.textContent='RUNNING';badge.style.background='#1d4ed8';badge.style.color='#bfdbfe';}
  fetch('/api/r6/handover-checks/run',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({bundle_dir:R6P.creds&&R6P.creds.gitops&&R6P.creds.gitops.localPath||'',bs_name:(R6P.bs&&R6P.bs.name)||''})})
  .then(function(r){return r.json();})
  .then(function(d){r6pPollHandover(d.run_id);})
  .catch(function(e){if(badge){badge.textContent='ERROR';badge.style.background='#7f1d1d';badge.style.color='#fca5a5';}});
};
window.r6pPollHandover=function(runId){
  if(!runId)return;
  var interval=setInterval(function(){
    fetch('/api/r6/handover-checks/runs/'+runId)
    .then(function(r){return r.json();})
    .then(function(d){
      r6pRenderHandoverResults(d);
      if(d.status==='done'||d.status==='error'||d.status==='cancelled')clearInterval(interval);
    }).catch(function(){clearInterval(interval);});
  },1500);
};
window.r6pRenderHandoverResults=function(d){
  var badge=document.getElementById('r6p-handover-status-badge');
  if(badge){var s=d.status||'unknown';badge.textContent=s.toUpperCase();badge.style.background=s==='done'?'#166534':s==='error'?'#7f1d1d':'#1d4ed8';badge.style.color=s==='done'?'#bbf7d0':s==='error'?'#fca5a5':'#bfdbfe';}
  var checks=d.checks||[];
  var pass=checks.filter(function(c){return c.status==='pass';}).length;
  var blocked=checks.filter(function(c){return c.status==='blocked';}).length;
  var warn=checks.filter(function(c){return c.status==='warning';}).length;
  var na=checks.filter(function(c){return c.status==='na';}).length;
  var score=checks.length?Math.round((pass/(checks.length-na||1))*100):0;
  [['score',score+'%'],['passed',pass],['warnings',warn],['blocked',blocked],['na',na],['total',checks.length],['duration',(d.duration_ms?(d.duration_ms/1000).toFixed(1)+'s':'—')]].forEach(function(p){var el=document.getElementById('r6p-hsc-'+p[0]);if(el)el.textContent=p[1];});
  var tbody=document.getElementById('r6p-handover-tbody');
  if(!tbody)return;
  if(!checks.length){tbody.innerHTML='<tr><td colspan="7" style="text-align:center;color:#94a3b8;padding:20px;">No checkpoint data yet.</td></tr>';return;}
  tbody.innerHTML=checks.map(function(c){
    var sc=c.status==='pass'?'#16a34a':c.status==='blocked'?'#dc2626':c.status==='warning'?'#d97706':'#94a3b8';
    var dot=c.status==='pass'?'&#10003;':c.status==='blocked'?'&#10007;':c.status==='warning'?'&#9651;':'&#9679;';
    return '<tr><td><span style="color:'+sc+';font-weight:700;">'+dot+'</span></td><td style="font-size:10px;color:#64748b;">'+( c.id||'')+'</td><td style="font-weight:600;">'+( c.name||'')+'</td><td style="font-size:11px;color:#475569;">'+( c.result||'')+'</td><td><span style="font-size:10px;font-weight:700;color:'+(c.blocking?'#dc2626':'#64748b')+'">'+(c.blocking?'YES':'—')+'</span></td><td style="font-size:11px;color:#64748b;">'+(c.duration_ms?(c.duration_ms)+'ms':'—')+'</td><td><button onclick="r6pHandoverRetryOne(\''+( c.id||'')+'\')" style="font-size:10px;background:#f1f5f9;border:1px solid #e2e8f0;border-radius:4px;padding:2px 6px;cursor:pointer;">Retry</button></td></tr>';
  }).join('');
  var dots=document.querySelectorAll('[data-check]');
  dots.forEach(function(el){var lbl=el.getAttribute('data-check');var match=checks.find(function(c){return c.name===lbl;});if(match){el.className='r6h-badge r6h-badge-'+(match.status==='pass'?'pass':match.status==='blocked'?'blocked':match.status==='warning'?'warning':'pending');el.textContent=match.status==='pass'?'Pass':match.status==='blocked'?'Blocked':match.status==='warning'?'Warning':'Pending';}});
};
window.r6pStopHandover=function(){};
window.r6pRetryHandover=function(){r6pRunHandoverCheck();};
window.r6pExportHandover=function(){var t=document.getElementById('r6p-handover-tbody');if(!t)return;var blob=new Blob([t.innerText],{type:'text/plain'});var a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download='r6_handover_check_'+Date.now()+'.txt';a.click();};
window.r6pHFilter=function(f){var rows=document.querySelectorAll('#r6p-handover-tbody tr');rows.forEach(function(r){r.style.display=(f==='all'||r.textContent.toLowerCase().indexOf(f)>=0)?'':'none';});};
window.r6pHSearch=function(q){var rows=document.querySelectorAll('#r6p-handover-tbody tr');rows.forEach(function(r){r.style.display=r.textContent.toLowerCase().indexOf(q.toLowerCase())>=0?'':'none';});};
window.r6pHandoverLoad=function(){var hp=document.getElementById('r6p-h-hostport');var phone=document.getElementById('r6p-handover-phone');if(hp&&hp.value&&phone){phone.innerHTML='<iframe src="http://'+hp.value+'" style="width:100%;height:100%;border:none;"></iframe>';}};
window.r6pHandoverHealth=function(){var hp=document.getElementById('r6p-h-hostport');if(!hp||!hp.value)return;var hh=document.getElementById('r6p-h-http');var hl=document.getElementById('r6p-h-lat');var t=Date.now();fetch('http://'+hp.value+'/health').then(function(r){if(hh)hh.textContent=r.status;if(hl)hl.textContent=(Date.now()-t)+'ms';}).catch(function(){if(hh)hh.textContent='ERR';});};
window.r6pHandoverReady=function(){r6pHandoverHealth();};
window.r6pHandoverLogin=function(){var hp=document.getElementById('r6p-h-hostport');if(hp&&hp.value)window.open('http://'+hp.value+'/login','_blank');};
/* Stage 13 "Load in R6 Phone Preview" - feeds a component's target host:port
   straight into the Handover section's phone mockup (r6p-handover-phone),
   the R6-native device preview, instead of sending the user out to Stage 4's
   separate UAT bench. */
window.r6pOpenMobileBench=function(compName){
  var c=(R6P.components||[]).find(function(x){return x.name===compName;});
  if(!c){alert('Component not found.');return;}
  var m=String(c.tgt||'').match(/^[a-zA-Z0-9+.-]+:\/\/([^\/:]+)(?::(\d+))?/);
  var host=m?m[1]:'', port=m&&m[2]?m[2]:'';
  if(!host){alert(c.name+' has no FLEX Target IP/URL yet - fill it in Step 1 Inspect first.');return;}
  var hp=document.getElementById('r6p-h-hostport');
  if(hp)hp.value=host+(port?':'+port:'');
  var section=document.getElementById('r6p-handover-section');
  if(section&&section.scrollIntoView)section.scrollIntoView({behavior:'smooth',block:'start'});
  setTimeout(function(){ if(typeof window.r6pHandoverLoad==='function')window.r6pHandoverLoad(); },350);
};
window.r6pHandoverRetryOne=function(id){};
window.r6pComponentCatalogRows=function(){
  var comps=R6P.components||[];
  if(!comps.length)return '<tr><td colspan="6" style="color:#64748b;font-style:italic;">No components selected yet.</td></tr>';
  return comps.map(function(c){
    var cls=r6pClassifyForComponent(c);
    var ep=r6pParseTargetEndpoint(c.tgt||'');
    var role=(c.type||c.role||r6pComponentProfile(c).category||'Application').replace(/^Component Type:\s*/i,'');
    var scan=R6P.depScan&&R6P.depScan[c.name];
    return '<tr><td style="font-weight:700;">'+c.name+'</td><td>'+role+'</td><td style="font-family:monospace;font-size:11px;color:#0369a1;">'+(c.tgt||'Not mapped')+'</td><td>'+(ep.port||'auto')+'</td><td>'+cls.state+'</td><td>'+(scan?'runtime-inspection.json ready':'pending live scan')+'</td></tr>';
  }).join('');
};
window.r6pDependencyGraphModel=function(){
  var comps=R6P.components||[];
  var role=function(c){var s=((c.type||c.role||'')+' '+(c.name||'')).toLowerCase();return /database|\bdb\b|mysql|postgres|mongo/.test(s)?'database':/cache|redis/.test(s)?'cache':/queue|rabbit|kafka/.test(s)?'queue':/gateway|\bapi\b/.test(s)?'gateway':/front|\bweb\b|mobile/.test(s)?'frontend':/backend|auth|identity|ledger|core|service/.test(s)?'backend':'service';};
  var endpoint=function(c){return r6pComponentTarget(c)||'Not mapped';};
  var scanned=function(c){return R6P.depScan&&R6P.depScan[c.name]&&R6P.depScan[c.name].appraisal;};
  var port=function(c,r){var ep=r6pParseTargetEndpoint(endpoint(c)),a=scanned(c),ports=(a&&a.ports)||[];if(ep&&ep.port)return ep.port;if(r==='database'){var db=ports.find(function(p){return [3306,5432,27017,6379].indexOf(Number(p))>=0;});return db||(/postgres/i.test(endpoint(c))?5432:3306);}var app=ports.find(function(p){return Number(p)>1024&&Number(p)!==22;});return app||((r==='gateway'||r==='frontend')?443:'unknown');};
  var groups={database:[],cache:[],queue:[],backend:[],gateway:[],frontend:[],service:[]};
  comps.forEach(function(c){groups[role(c)].push(c);});
  var rows=[],seen={};
  var add=function(from,to,why){
    if(!from||!to||from===to)return;
    var key=from.name+'>'+to.name;if(seen[key])return;seen[key]=true;
    var pr=role(to),p=port(to,pr),isDb=pr==='database',isTls=/^https:|sslmode=require|tls/i.test(endpoint(to));
    rows.push({from:from.name,to:to.name,proto:isDb?'mysql/postgresql':'http'+(isTls?'s':'')+'/tcp',port:p,endpoint:endpoint(to),
      auth:isDb?'credential/secret reference required':'application auth to confirm',
      tls:isTls?'TLS configured':'TLS to confirm',order:(pr==='database'||pr==='cache'||pr==='queue')?'1 - data services':pr==='backend'?'2 - backend/auth':pr==='gateway'?'3 - API gateway':'4 - web frontend',
      evidence:(scanned(from)?'live scan + ':'')+why});
  };
  groups.frontend.forEach(function(c){(groups.gateway.length?groups.gateway:groups.backend).forEach(function(p){add(c,p,'role topology');});});
  groups.gateway.forEach(function(c){groups.backend.forEach(function(p){add(c,p,'role topology');});});
  groups.backend.concat(groups.service).forEach(function(c){groups.database.concat(groups.cache,groups.queue).forEach(function(p){add(c,p,'role topology');});});
  comps.forEach(function(c){
    var declared=c.dependencies||c.dependsOn||c.depends_on||[];
    if(typeof declared==='string')declared=declared.split(/[,;\n]/);
    (declared||[]).forEach(function(name){var p=comps.find(function(x){return String(name).toLowerCase().indexOf(String(x.name).toLowerCase())>=0||String(x.name).toLowerCase().indexOf(String(name).trim().toLowerCase())>=0;});if(p)add(c,p,'declared dependency');});
  });
  return rows;
};
window.r6pDependencyGraphRows=function(){
  var rows=r6pDependencyGraphModel();
  if(!(R6P.components||[]).length)return '<tr><td colspan="9" style="color:#64748b;font-style:italic;">No components selected yet.</td></tr>';
  if(!rows.length)return '<tr><td colspan="9" style="color:#d97706;">No credible dependency relationship is available. Add declared dependencies or run the live scan; no full-mesh graph was assumed.</td></tr>';
  return rows.map(function(r){return '<tr><td style="font-weight:700;">'+r.from+'</td><td>'+r.to+'</td><td>'+r.proto+'</td><td>'+r.port+'</td><td>'+r.endpoint+'</td><td>'+r.auth+'</td><td>'+r.tls+'</td><td>'+r.order+'</td><td style="font-size:11px;color:#64748b;">'+r.evidence+'</td></tr>';}).join('');
};
window.r6pNormalizedDiscoveryRows=function(){
  var comps=R6P.components||[];
  if(!comps.length)return '<tr><td colspan="5" style="color:#64748b;font-style:italic;">No components selected yet.</td></tr>';
  return comps.map(function(c){
    var reachable=!!(R6P.depScan&&R6P.depScan[c.name]);
    var form=(R6P.targetForms&&R6P.targetForms[c.name])||r6pDecideTargetForm(c).form;
    var fallback=(form==='CONTAINERIZED'||form==='PARTIALLY_CONTAINERIZED')?'Stage 9 snapshot eligible':'no container snapshot required';
    return '<tr><td style="font-weight:700;">'+c.name+'</td><td>'+(c.tgt||'Not mapped')+'</td><td><span style="color:'+(reachable?'#16a34a':'#d97706')+';font-weight:700;">'+(reachable?'reachable / scanned':'not scanned yet')+'</span></td><td>'+fallback+'</td><td style="font-size:11px;color:#64748b;">normalized-discovery.json</td></tr>';
  }).join('');
};
window.r6pContent=function(n){
  if(n===0)return r6pStage0();
  if(n===1)return '<div class="r6p-warn-box">Only FLEX workloads can be converted here. Complete migration to FLEX first.</div><div class="uat-s1-biz-grid"><div><div style="font-weight:800;font-size:15px;color:#0f172a;margin-bottom:12px;">Business Systems <span style="font-size:11px;color:#64748b;font-weight:400;">from FLEX Migration Log</span></div><div id="r6p-biz-list" style="min-height:180px;"></div>'
    +'</div><div class="uat-s1-arch-selector"><div class="uat-s1-arch-head"><div class="uat-s1-arch-title">Business System Templates</div><span class="uat-s1-arch-badge">10 Templates</span></div><p class="uat-s1-arch-desc">Templates define structure only. Conversion requires real FLEX VM/DB mapping.</p><div class="uat-s1-template-pane active"><div id="r6p-arch-grid" class="uat-s1-arch-grid"></div></div></div></div>'+r6pFoot(1);
  if(n===2){
    var comps2=R6P.components||[];
    return '<div class="r6p-info-box">Refresh the selected Business System inventory before runtime inspection. This confirms current FLEX VM IDs, states, IPs, attached volumes, networks and existing snapshot metadata; it does not create snapshots.</div>'
      +'<div style="display:grid;grid-template-columns:repeat(5,1fr);gap:8px;margin-bottom:14px;">'
      +[['Components',comps2.length],['Mapped endpoints',comps2.filter(function(c){return c.tgt;}).length],['Attached-volume hints',comps2.filter(function(c){return /database|db|storage|queue|cache/i.test(c.name||c.type||'');}).length],['Live scans',R6P.depScan?Object.keys(R6P.depScan).length:0],['Snapshot action','Stage 9 only']].map(function(x){return '<div style="background:#f8fafc;border:1px solid #e2e8f0;border-radius:8px;padding:9px 12px;text-align:center;"><div style="font-size:16px;font-weight:900;color:#0369a1;">'+x[1]+'</div><div style="font-size:9px;font-weight:800;color:#64748b;text-transform:uppercase;">'+x[0]+'</div></div>';}).join('')
      +'</div>'
      +'<pre style="background:#0f172a;color:#7dd3fc;border-radius:8px;padding:12px;font-size:11px;white-space:pre-wrap;max-height:180px;overflow:auto;">hydrated-source-system.json\n'+JSON.stringify({businessSystem:R6P.bs&&R6P.bs.name||null,components:comps2.map(function(c){return {name:c.name,target:c.tgt||'',source:c.src||'',health:c.path||'',type:c.type||''};})},null,2)+'</pre>'
      +r6pFoot(n);
  }
  if(n===3){
    var comps6=(R6P.components||[]);
    var defaultScanConnection=r6pInputConnectionFor(comps6[0]||{});
    var scanOptions=comps6.length?'<option value="__all__">All components scan ('+comps6.length+')</option>'+comps6.map(function(c,i){return '<option value="'+i+'">'+r6pHtml(c.name)+' — '+r6pHtml(r6pComponentTarget(c)||'mapping required')+'</option>';}).join(''):'<option value="">No components</option>';
    var pendingCards=comps6.map(function(c){
      var endpoint=r6pComponentTarget(c),vm=c.vmId||c.vm_id||c.sourceVmId||c.name;
      return '<div style="border:1px solid #cbd5e1;border-top:4px solid #94a3b8;border-radius:9px;background:#fff;padding:13px;">'
        +'<div style="display:flex;justify-content:space-between;gap:8px;"><strong>'+r6pHtml(c.name)+'</strong><span style="font-size:10px;color:#64748b;font-weight:900;">NOT_TESTED</span></div>'
        +'<div style="font-size:11px;color:#64748b;margin:5px 0;">Source VM: '+r6pHtml(vm)+'</div>'
        +'<div style="font-size:11px;color:#334155;">Endpoint: '+r6pHtml(endpoint)+'<br>Connectivity: Pending<br>Runtime: Pending<br>Services: Pending<br>Ports: Pending<br>Application paths: Pending<br>Persistence: Pending<br>Dependencies: Pending<br>Health: Not tested<br>Secret safety: Not tested</div>'
        +'<div style="display:flex;gap:12px;font-size:12px;margin-top:8px;"><b>Readiness —</b><b>Evidence —</b></div>'
        +'<div style="font-size:11px;color:#64748b;margin-top:7px;">Capture: Pending appraisal<br>Container recommendation: Pending appraisal</div>'
        +'</div>';
    }).join('');
    var pendingAppraisal='<div style="border:2px solid #94a3b8;border-radius:10px;padding:14px;margin-bottom:14px;background:#fff;">'
      +'<div style="display:flex;justify-content:space-between;gap:10px;"><div><h3 style="margin:0 0 4px;">Business Apps System Scan Appraisal</h3><div style="font-size:12px;color:#64748b;">'+r6pHtml((R6P.bs&&R6P.bs.name)||'Selected Business Apps System')+'</div></div><span style="color:#64748b;font-weight:900;">NOT_TESTED</span></div>'
      +'<div style="margin-top:10px;font-size:12px;"><b>'+comps6.length+' logical components queued</b> &bull; 0 probes executed &bull; Final verdict pending</div>'
      +'<div style="margin-top:6px;font-size:11px;color:#64748b;">Run the full live scan to calculate evidence completeness, container readiness, warnings, blockers and the Stage 8 recommendation.</div>'
      +'</div>';
    var pendingResults='<div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(290px,1fr));gap:12px;">'+pendingCards+'</div>';
    return '<div class="r6p-info-box"><strong>Component Scan Appraisal</strong><br>Evaluate the runtime, services, application files, dependencies, storage, health, security and containerization constraints of every Business Apps System component. Twenty independent, allowlisted probes preserve exit code, stdout, stderr, timeout and truncation evidence. No snapshots are created.</div>'
      +'<div style="display:flex;gap:10px;flex-wrap:wrap;align-items:flex-end;margin-bottom:14px;">'
      +'<div><label style="font-size:11px;font-weight:700;color:#334155;display:block;margin-bottom:4px;">Component scan scope</label><select id="r6p-scan-comp" onchange="r6pScanScopeChanged()" style="padding:7px;border:1px solid #cbd5e1;border-radius:6px;font-size:12px;min-width:310px;">'+scanOptions+'</select></div>'
      +'<div><label style="font-size:11px;font-weight:700;color:#334155;display:block;margin-bottom:4px;">SSH User</label><input id="r6p-scan-user" value="'+r6pHtml(defaultScanConnection.sshUser||'ubuntu')+'" style="padding:7px;border:1px solid #cbd5e1;border-radius:6px;font-size:12px;width:100px;"></div>'
      +'<div><label style="font-size:11px;font-weight:700;color:#334155;display:block;margin-bottom:4px;">SSH Private Key Path / Secret Ref</label><input id="r6p-scan-key" value="'+r6pHtml(defaultScanConnection.sshKeyPath||'~/.ssh/id_rsa')+'" style="padding:7px;border:1px solid #cbd5e1;border-radius:6px;font-size:12px;width:190px;"></div>'
      +'<div><label style="font-size:11px;font-weight:700;color:#334155;display:block;margin-bottom:4px;">Managed known_hosts</label><input id="r6p-scan-known-hosts" value="./data/ssh/known_hosts" style="padding:7px;border:1px solid #cbd5e1;border-radius:6px;font-size:12px;width:180px;"></div>'
      +'<button id="r6p-full-scan-btn" class="r6p-btn primary" onclick="r6pStartProductionScan()" style="padding:8px 16px;font-size:12px;">&#9654; Run Scan</button>'
      +'<button id="r6p-stop-scan-btn" class="r6p-btn secondary" onclick="r6pStopProductionScan()" style="padding:8px 16px;font-size:12px;" disabled>Stop Scan</button>'
      +'<button class="r6p-btn secondary" onclick="r6pCheckSelectedComponentHostIdentity()" style="padding:8px 16px;font-size:12px;">SSH Host Identity</button>'
      +'<button class="r6p-btn secondary" onclick="r6pRefreshAppraisal()" style="padding:8px 16px;font-size:12px;">Refresh Appraisal</button>'
      +'<button class="r6p-btn secondary" onclick="r6pExportProductionScan()" style="padding:8px 16px;font-size:12px;">&#11015; Export Evidence</button>'
      +'<button class="r6p-btn secondary" onclick="r6pExportAllAppraisalsCsv()" style="padding:8px 16px;font-size:12px;">&#11015; Export All Appraisal Results CSV</button>'
      +'</div>'
      +r6pProductionScanTerminal()
      +'<div id="r6p-scan-appraisal">'+(comps6.length?pendingResults:'<div class="r6p-warn-box">No components with FLEX target endpoints are available. Select and inspect a Business System in Stage 1 first.</div>')+'</div>'
      +'<div id="r6p-scan-final-verdict">'+(comps6.length?pendingAppraisal:'')+'</div>'
      +'<div id="r6p-scan-failed-checks"></div>'
      +'<div id="r6p-appraisal-drawer" style="display:none;position:fixed;inset:0;z-index:10020;background:rgba(15,23,42,.55);" onclick="if(event.target===this)r6pCloseAppraisal()"><div style="position:absolute;right:0;top:0;bottom:0;width:min(760px,94vw);background:#fff;overflow:auto;padding:20px;box-shadow:-8px 0 30px #0f172a55;"><button class="r6p-btn secondary" onclick="r6pCloseAppraisal()" style="float:right;">Close</button><div id="r6p-appraisal-detail"></div></div></div>'
      +r6pFoot(n);
  }
  if(n===4){
    return '<div class="r6p-info-box">Convert VM-level topology and live-scan evidence into application components: frontend, API, backend, worker, scheduler, database, cache, queue and storage.</div>'
      +'<div style="overflow-x:auto;margin-bottom:14px;"><table class="r6p-table"><thead><tr><th>Component</th><th>Role / Category</th><th>Current FLEX Endpoint</th><th>Port</th><th>Initial State</th><th>Evidence</th></tr></thead><tbody>'+r6pComponentCatalogRows()+'</tbody></table></div>'
      +'<pre style="background:#0f172a;color:#c4b5fd;border-radius:8px;padding:12px;font-size:11px;white-space:pre-wrap;max-height:160px;overflow:auto;">component-catalog.json\n'+JSON.stringify((R6P.components||[]).map(function(c){return {name:c.name,type:c.type||'',target:c.tgt||'',health:c.path||'',runtime:r6pGuessRuntime(c)};}),null,2)+'</pre>'
      +r6pFoot(n);
  }
  if(n===5){
    return '<div class="r6p-info-box">Define consumer/provider relationships, protocols, ports, current endpoints, authentication/TLS placeholders and startup order. Live-scan evidence strengthens this graph when available.</div>'
      +'<div style="overflow-x:auto;margin-bottom:14px;"><table class="r6p-table"><thead><tr><th>Consumer</th><th>Provider</th><th>Protocol</th><th>Port</th><th>Current endpoint</th><th>Authentication</th><th>TLS</th><th>Startup order</th><th>Evidence</th></tr></thead><tbody>'+r6pDependencyGraphRows()+'</tbody></table></div>'
      +'<pre style="background:#0f172a;color:#7dd3fc;border-radius:8px;padding:12px;font-size:11px;white-space:pre-wrap;max-height:180px;overflow:auto;">dependency-graph.yaml\n# directional graph; unknowns are explicit\n'+r6pDependencyGraphModel().map(function(r){return '- consumer: '+r.from+'\n  provider: '+r.to+'\n  protocol: '+r.proto+'\n  port: '+r.port+'\n  endpoint: '+r.endpoint+'\n  authentication: '+r.auth+'\n  tls: '+r.tls+'\n  startup_order: '+r.order;}).join('\n')+'</pre>'
      +r6pFoot(n);
  }
  if(n===6){
    return '<div class="r6p-info-box">Merge imported topology and live inspection results. Mark unreachable VMs and record snapshot fallback availability for Stage 9 only.</div>'
      +'<div style="overflow-x:auto;margin-bottom:14px;"><table class="r6p-table"><thead><tr><th>Component</th><th>Endpoint</th><th>Runtime Evidence</th><th>Snapshot Fallback</th><th>Output</th></tr></thead><tbody>'+r6pNormalizedDiscoveryRows()+'</tbody></table></div>'
      +'<pre style="background:#0f172a;color:#2dd4bf;border-radius:8px;padding:12px;font-size:11px;white-space:pre-wrap;max-height:180px;overflow:auto;">normalized-discovery.json\n'+JSON.stringify({businessSystem:R6P.bs&&R6P.bs.name||null,scanned:Object.keys(R6P.depScan||{}),components:(R6P.components||[]).map(function(c){return {name:c.name,reachable:!!(R6P.depScan&&R6P.depScan[c.name]),snapshotFallback:'Stage 9 only after decision'};})},null,2)+'</pre>'
      +r6pFoot(n);
  }
  if(n===7){var rows7=[
      ['app_code','Container image','Include','Your actual application code (binaries, scripts, compiled assets). This is what gets COPYed into the Dockerfile.'],
      ['config_template','ConfigMap','Include','Non-secret config files (*.conf, *.yaml, *.ini, env templates). Becomes a Kubernetes ConfigMap, mounted into the pod.'],
      ['secret_candidate','SOPS Secret','Include','Files that look like they hold credentials (passwords, API keys, certs). SOPS-encrypted and turned into a Kubernetes Secret - never baked into the image.'],
      ['log_file','stdout/stderr','Exclude','Application log files. Containers should log to stdout/stderr instead - these are left behind, not copied.'],
      ['database_data','ExternalDB','Exclude','Actual database files/data directories. Databases stay external (RDS/managed DB) - never baked into a container image.'],
      ['excluded_file','Excluded','Exclude','OS/system files, caches, temp files - not part of the application, always left out.']
    ];
    var comps7=(R6P.components||[]).filter(function(c){return c.tgt;});
    var opts7=comps7.length?comps7.map(function(c,i){return '<option value="'+i+'">'+c.name+' ('+c.tgt+')</option>';}).join(''):'<option value="">No components have a FLEX Target IP yet - go to Step 1, click Inspect on the selected system, and fill in Target IP for each component</option>';
    return '<div class="r6p-info-box">Identify real application content. Classify files into app content, config, secrets, logs, data, and excluded system files.</div>'
      +'<div style="display:flex;gap:10px;flex-wrap:wrap;align-items:flex-end;margin-bottom:14px;">'
      +'<div><label style="font-size:11px;font-weight:700;color:#334155;display:block;margin-bottom:4px;">Component</label><select id="r6p-classify-comp" style="padding:7px;border:1px solid #cbd5e1;border-radius:6px;font-size:12px;min-width:260px;">'+opts7+'</select></div>'
      +'<div><label style="font-size:11px;font-weight:700;color:#334155;display:block;margin-bottom:4px;">SSH User</label><input id="r6p-classify-user" value="root" style="padding:7px;border:1px solid #cbd5e1;border-radius:6px;font-size:12px;width:100px;"></div>'
      +'<div><label style="font-size:11px;font-weight:700;color:#334155;display:block;margin-bottom:4px;">SSH Key Path</label><input id="r6p-classify-key" value="~/.ssh/id_rsa" style="padding:7px;border:1px solid #cbd5e1;border-radius:6px;font-size:12px;width:160px;"></div>'
      +'<button class="r6p-btn primary" onclick="r6pRunClassify()" style="padding:8px 16px;font-size:12px;">&#9654; Check</button>'
      +'</div>'
      +'<div style="overflow-x:auto;margin-bottom:14px;"><table class="r6p-table"><thead><tr><th>Classification</th><th>K8s Target</th><th>What This Means</th><th>Include/Exclude</th><th>Files Found</th></tr></thead><tbody>'
      +rows7.map(function(r){return '<tr><td style="font-weight:600;">'+r[0]+'</td><td style="color:#7c3aed;font-size:11px;">'+r[1]+'</td><td style="color:#64748b;font-size:11px;max-width:280px;">'+r[3]+'</td><td><span style="background:'+(r[2]==='Include'?'#dcfce7':'#fee2e2')+';color:'+(r[2]==='Include'?'#16a34a':'#dc2626')+';padding:2px 8px;border-radius:999px;font-size:10px;font-weight:700;">'+r[2]+'</span></td><td id="r6p-classify-count-'+r[0]+'" style="font-size:11px;color:#94a3b8;">Not checked</td></tr>';}).join('')
      +'</tbody></table></div>'
      +'<div id="r6p-classify-out" class="r6p-terminal" style="display:none;max-height:220px;"></div>'
      +'<div style="font-weight:800;font-size:13px;color:#0f172a;margin:20px 0 8px;">Classify: Component State &amp; Portability</div>'
      +'<div class="r6p-info-box">State/portability classification for every real selected component, using the same reference engine as the Component Containerization Chart. Override any row if the automatic classification is wrong - overrides are saved and also apply to the Step 8 Transform target-form decision.</div>'
      +(!(R6P.components||[]).length?'<div class="r6p-warn-box">No components selected. Go back to Step 1 and select a Business System.</div>':
      '<div style="overflow-x:auto;"><table class="r6p-table"><thead><tr><th>Component</th><th>State</th><th>Default Decision</th><th>Override</th></tr></thead><tbody>'
      +(R6P.components||[]).map(function(c){
        var cls=r6pClassifyForComponent(c);
        var dot=cls.state==='Stateless'?'#16a34a':cls.state==='Stateful'?'#dc2626':'#d97706';
        var opts=['Stateless','Stateful','Unknown / mixed'].map(function(st){return '<option value="'+st+'"'+(st===cls.state?' selected':'')+'>'+st+'</option>';}).join('');
        return '<tr><td style="font-weight:600;">'+c.name+'</td><td><span style="background:'+dot+'22;color:'+dot+';padding:2px 8px;border-radius:999px;font-size:10px;font-weight:700;">'+cls.state+'</span></td><td style="font-size:11px;color:#64748b;max-width:280px;">'+cls.decision+'</td><td><select onchange="r6pSetClassifyOverride(\''+c.name.replace(/'/g,"\\'")+'\',this.value)" style="padding:4px 6px;border:1px solid #cbd5e1;border-radius:5px;font-size:11px;">'+opts+'</select></td></tr>';
      }).join('')
      +'</tbody></table></div>')
      +r6pFoot(7);}
  if(n===8){var comps8=R6P.components&&R6P.components.length?R6P.components:[];
    if(!comps8.length)return '<div class="r6p-warn-box">No components selected. Go back to Step 1 and select a Business System or standalone VM/DB.</div>'+r6pFoot(8);
    var decisions=comps8.map(function(c){return r6pDecideMigrationMode(c);});
    var counts={CLOUD_NATIVE_READY:0,READY_WITH_EXTERNALIZATION:0,KEEP_ON_FLEX_VM_FOR_NOW:0,COMPATIBILITY_CONTAINER_ONLY:0,BLOCKED:0};
    decisions.forEach(function(d){counts[d.status]=(counts[d.status]||0)+1;});
    var tiles=[['CLOUD_NATIVE_READY','#dcfce7','#16a34a'],['READY_WITH_EXTERNALIZATION','#fef3c7','#d97706'],['KEEP_ON_FLEX_VM_FOR_NOW','#dbeafe','#1d4ed8'],['COMPATIBILITY_CONTAINER_ONLY','#faf5ff','#7c3aed'],['BLOCKED','#fee2e2','#dc2626']];
    var missingScans=comps8.filter(function(c){return r6pComponentTarget(c)&&!(R6P.depScan&&R6P.depScan[c.name]&&R6P.depScan[c.name].completed===true)&&!r6pAppraisalAllowsStage8(c);});
    var allCanProceed=decisions.every(function(d){return d.status!=='BLOCKED';});
    return '<div class="r6p-info-box">Migration mode decision engine - evaluates each component'+"'"+'s type, OS, and Steps 3-6 discovery evidence to assign container, operator, VM, external, data-migration, manual-review or blocked targets.</div>'
      +'<div style="display:grid;grid-template-columns:repeat(5,1fr);gap:8px;margin-bottom:14px;">'
      +tiles.map(function(b){return '<div style="background:'+b[1]+';border-radius:8px;padding:10px;text-align:center;"><div style="font-size:16px;font-weight:900;color:'+b[2]+';">'+(counts[b[0]]||0)+'</div><div style="font-size:9px;color:'+b[2]+';font-weight:700;margin-top:2px;">'+b[0].replace(/_/g,' ')+'</div></div>';}).join('')
      +'</div><div style="overflow-x:auto;"><table class="r6p-table"><thead><tr><th>Component</th><th>Workload Type</th><th>Readiness</th><th>Reason</th><th>Recommended Method</th><th>Can Proceed</th></tr></thead><tbody>'
      +decisions.map(function(d){var rc={CLOUD_NATIVE_READY:['#dcfce7','#16a34a'],READY_WITH_EXTERNALIZATION:['#fef3c7','#d97706'],KEEP_ON_FLEX_VM_FOR_NOW:['#dbeafe','#1d4ed8'],COMPATIBILITY_CONTAINER_ONLY:['#faf5ff','#7c3aed'],BLOCKED:['#fee2e2','#dc2626']}[d.status];
        return '<tr><td style="font-weight:600;">'+d.name+'</td><td style="font-size:11px;color:#64748b;">'+d.workloadType+'</td><td><span style="background:'+rc[0]+';color:'+rc[1]+';padding:2px 8px;border-radius:999px;font-size:10px;font-weight:700;">'+d.status.replace(/_/g,' ')+'</span></td><td style="font-size:11px;color:#64748b;max-width:220px;">'+d.reason+'</td><td style="font-size:11px;color:#0369a1;font-weight:700;">'+d.method+'</td><td><span style="background:'+(d.status==='BLOCKED'?'#fee2e2':'#dcfce7')+';color:'+(d.status==='BLOCKED'?'#dc2626':'#16a34a')+';padding:2px 8px;border-radius:999px;font-size:10px;font-weight:700;">'+(d.status==='BLOCKED'?'No':'Yes')+'</span></td></tr>';}).join('')
      +'</tbody></table></div>'
      +(missingScans.length?'<div class="r6p-warn-box" style="margin-top:10px;">Live scan not yet run (advisory only; approval is allowed): '+missingScans.map(function(c){return c.name;}).join(', ')+'</div>':'')
      +(decisions.some(function(d){return d.status==='BLOCKED';})?'<div class="r6p-warn-box" style="margin-top:10px;">One or more components are BLOCKED - resolve before approving.</div>':'')
      +'<div style="font-weight:800;font-size:13px;color:#0f172a;margin:20px 0 8px;">Transform: Target Runtime Decision (Hybrid)</div>'
      +'<div class="r6p-info-box">Assigns every real selected component one of 11 target forms - CONTAINERIZED, KUBERNETES_NATIVE, OPERATOR_MANAGED, RETAINED_FLEX_VM, REDEPLOYED_FLEX_VM, EXTERNAL_SERVICE, DATA_MIGRATION_REQUIRED, PARTIALLY_CONTAINERIZED, MANUAL_REVIEW, BLOCKED or EXCLUDED. Engineers can override any row - overrides are saved per component.</div>'
      +'<div style="overflow-x:auto;"><table class="r6p-table"><thead><tr><th>Component</th><th>State</th><th>Containerized</th><th>Default Target Form</th><th>UI Decision Badge</th><th>Lifecycle</th><th>Required Gate Before Deploy</th><th>Reason</th><th>Override</th></tr></thead><tbody>'
      +comps8.map(function(c){
        var tf=r6pDecideTargetForm(c);
        var saved=(R6P.targetForms&&R6P.targetForms[c.name])||tf.form;
        var badge=r6pBadgeForTargetForm(saved);
        var gate=r6pRequiredGateFor(saved);
        var cls=r6pClassifyForComponent(c);
        var isContainerized=(badge[0]==='Containerize'||badge[0]==='Partially Containerize')?'Yes':(badge[0]==='Deploy with Operator'?'No direct conversion':'No');
        var lc=r6pLifecycleFor(c);
        var stDot=cls.state==='Stateless'?'#16a34a':cls.state==='Stateful'?'#dc2626':'#d97706';
        var opts=R6_TARGET_FORMS.map(function(r){return '<option value="'+r[0]+'"'+(r[0]===saved?' selected':'')+'>'+r[0]+'</option>';}).join('');
        return '<tr><td style="font-weight:600;">'+c.name+'</td><td><span style="background:'+stDot+'22;color:'+stDot+';padding:2px 8px;border-radius:999px;font-size:10px;font-weight:700;">'+cls.state+'</span></td><td style="font-size:11px;color:#334155;">'+isContainerized+'</td><td><span style="background:#eff6ff;color:#0369a1;padding:2px 8px;border-radius:999px;font-size:10px;font-weight:700;">'+saved+'</span></td><td><span style="background:'+badge[1]+'22;color:'+badge[1]+';padding:2px 8px;border-radius:999px;font-size:10px;font-weight:700;">'+badge[0]+'</span></td><td style="font-size:10px;color:#7c3aed;font-weight:700;">'+lc.replace(/_/g,' ')+'</td><td style="font-size:11px;color:#64748b;max-width:180px;">'+gate+'</td><td style="font-size:11px;color:#64748b;max-width:200px;">'+tf.reason+'</td><td><select onchange="r6pSetTargetForm(\''+c.name.replace(/'/g,"\\'")+'\',this.value)" style="padding:4px 6px;border:1px solid #cbd5e1;border-radius:5px;font-size:11px;">'+opts+'</select></td></tr>';
      }).join('')
      +'</tbody></table></div>'
      +'<div class="r6p-stage-footer"><button class="r6p-btn success" onclick="r6pMarkDone(8)"'+(allCanProceed?'':' disabled')+'>Approve Readiness Plan</button>'
      +'<button class="r6p-btn primary" onclick="r6pGoTo(9)"'+(allCanProceed?'':' disabled')+'>Continue</button></div>';}
  if(n===9){
    var buildableComps9=(R6P.components||[]).filter(function(c){
      var form=(R6P.targetForms&&R6P.targetForms[c.name])||r6pDecideTargetForm(c).form;
      return (form==='CONTAINERIZED'||form==='PARTIALLY_CONTAINERIZED')&&!r6pStage9IsDatabaseLike(c);
    });
    var stage9Rows=[
      ['9.1','Read Stage 8 decisions','Every component'],
      ['9.2','Select CONTAINERIZED and PARTIALLY_CONTAINERIZED components','Container targets only'],
      ['9.3','Reuse an approved existing snapshot or create a new VM/volume snapshot','Container targets requiring extraction'],
      ['9.4','Wait until snapshot is available','Snapshot targets'],
      ['9.5','Mount or expose snapshot read-only','Snapshot targets'],
      ['9.6','Extract only approved application paths','Container targets'],
      ['9.7','Remove secrets, logs, temporary files, host keys, backups and database files','Every extracted context'],
      ['9.8','Calculate source checksum and record lineage','Every extracted context'],
      ['9.9','Generate Dockerfile and build configuration','Custom container targets'],
      ['9.10','Build and start-test the image','Custom container targets'],
      ['9.11','Compare container ports, runtime, health and dependencies with live-scan evidence','Custom container targets'],
      ['9.12','Generate SBOM and vulnerability scan','Custom container targets'],
      ['9.13','Push and optionally sign the image','Successful images'],
      ['9.14','Resolve immutable digest and update component state','Successful images'],
      ['9.15','Preserve VM image, network, volume and cloud-init definitions','Retained/redeployed VM targets']
    ].map(function(r){return '<tr><td style="font-weight:800;color:#0369a1;">'+r[0]+'</td><td>'+r[1]+'</td><td style="font-size:11px;color:#64748b;">'+r[2]+'</td></tr>';}).join('');
    var decisionRows=[
      ['CONTAINERIZED','Snapshot or clone application source','Build custom OCI image'],
      ['PARTIALLY_CONTAINERIZED','Snapshot execution files, exclude durable state','Build image plus external storage/data plan'],
      ['OPERATOR_MANAGED','No normal VM filesystem snapshot','Generate operator CR and data migration plan'],
      ['RETAINED_FLEX_VM','No containerization snapshot','Preserve VM definition and Service binding'],
      ['REDEPLOYED_FLEX_VM','Preserve VM image/volume source','Generate OpenCenter VM provisioning definition'],
      ['EXTERNAL_SERVICE','No snapshot','Generate Service/DNS/Secret contract'],
      ['DATA_MIGRATION_REQUIRED','Use native migration method','Generate migration commands and validation'],
      ['BLOCKED','No snapshot','Stop pipeline for that component'],
      ['EXCLUDED','No action','Component omitted']
    ].map(function(r){return '<tr><td style="font-weight:800;">'+r[0]+'</td><td>'+r[1]+'</td><td style="font-size:11px;color:#64748b;">'+r[2]+'</td></tr>';}).join('');
    var startCmdRows=buildableComps9.map(function(c){
      var detected=(R6P.startCmdOverride&&R6P.startCmdOverride[c.name])||r6pDetectStartCommand(c);
      var missing=!detected;
      return '<tr><td style="font-weight:600;">'+c.name+'</td>'
        +'<td><input value="'+(detected||'').replace(/"/g,'&quot;')+'" placeholder="e.g. node server.js / java -jar app.jar" '
        +'onchange="r6pSetStartCommand(\''+c.name.replace(/'/g,"\\'")+'\',this.value)" '
        +'style="width:100%;padding:5px 7px;border:1px solid '+(missing?'#fca5a5':'#cbd5e1')+';border-radius:5px;font-size:11px;font-family:monospace;"></td>'
        +'<td>'+(missing?'<span style="color:#dc2626;font-size:10px;font-weight:700;">Not detected - run Live Scan or set manually</span>':'<span style="color:#16a34a;font-size:10px;font-weight:700;">Detected from Live Scan</span>')+'</td></tr>';
    }).join('');
    return '<div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:6px;"><div style="font-weight:800;font-size:13px;color:#0f172a;">Approved Container Source Capture</div>'
    +'<button onclick="r6pPreviewArtifact(\'source-lineage.json\')" style="background:#f1f5f9;color:#334155;border:1px solid #e2e8f0;border-radius:4px;padding:3px 10px;font-size:10px;cursor:pointer;">Preview snapshot lineage</button></div>'
    +'<div style="overflow-x:auto;margin-bottom:14px;"><table class="r6p-table"><thead><tr><th>Component</th><th>Source VM</th><th>Decision</th><th>Snapshot</th><th>Snapshot ID</th><th>Extraction</th><th>Build</th></tr></thead><tbody id="r6p-capture-tbody">'+r6pBuildCaptureRows()+'</tbody></table></div>'
    +'<div style="background:#f8fafc;border:1px solid #bfdbfe;border-radius:10px;padding:12px 14px;margin-bottom:14px;">'
    +'<div style="font-size:14px;font-weight:900;color:#0f172a;margin-bottom:4px;">Stage 9A — Build VM Snapshots</div>'
    +'<div style="font-size:11px;color:#475569;margin-bottom:10px;">Create or reuse OpenStack VM image / Cinder volume snapshots for approved container-source VMs only. Stage 9A records the exact OpenStack snapshot IDs from the CLI, verifies them with image/volume snapshot show, then hands those IDs to container build.</div>'
    +'<button class="r6p-btn primary" onclick="r6pGenRealDockerfiles(true)" style="padding:8px 16px;font-size:12px;">&#9654; Build VM Snapshots</button>'
    +'<div id="r6p-snapshot-status" style="font-size:12px;font-weight:600;color:#64748b;margin-top:8px;line-height:1.7;"></div>'
    +'</div>'
    +'<div style="background:#ffffff;border:1px solid #e2e8f0;border-radius:10px;padding:12px 14px;margin-bottom:14px;">'
    +'<div style="font-size:14px;font-weight:900;color:#0f172a;margin-bottom:4px;">Stage 9B — Build Containers</div>'
    +'<div style="font-size:11px;color:#475569;margin-bottom:10px;">After snapshot lineage is available, extract approved application paths read-only, sanitize context, build/test/scan/sign/push images and record final registry digests.</div>'
    +'<div style="display:flex;gap:10px;flex-wrap:wrap;align-items:flex-end;margin-bottom:14px;">'
    +'<div><label style="font-size:11px;font-weight:700;color:#334155;display:block;margin-bottom:4px;">Registry</label><select id="r6p-build-regtype" style="padding:7px;border:1px solid #cbd5e1;border-radius:6px;font-size:12px;"><option value="harbor" selected>Harbor (in-cluster, recommended default)</option><option value="dockerhub">Docker Hub</option><option value="ghcr">GitHub Container Registry</option><option value="gitlab">GitLab Container Registry</option><option value="quay">Quay.io</option><option value="ecr">AWS ECR (private)</option><option value="ecrpublic">AWS ECR Public</option><option value="gcp">GCP Artifact Registry</option><option value="custom">Custom OCI URL</option></select></div>'
    +'<div><label style="font-size:11px;font-weight:700;color:#334155;display:block;margin-bottom:4px;">Registry URL (optional)</label><input id="r6p-build-regurl" placeholder="registry.example.com" style="padding:7px;border:1px solid #cbd5e1;border-radius:6px;font-size:12px;width:200px;"></div>'
    +'<div><label style="font-size:11px;font-weight:700;color:#334155;display:block;margin-bottom:4px;">Project</label><input id="r6p-build-project" value="flex-apps" style="padding:7px;border:1px solid #cbd5e1;border-radius:6px;font-size:12px;width:120px;"></div>'
    +'<div><label style="font-size:11px;font-weight:700;color:#334155;display:block;margin-bottom:4px;">Registry User</label><input id="r6p-build-reguser" placeholder="admin" style="padding:7px;border:1px solid #cbd5e1;border-radius:6px;font-size:12px;width:100px;"></div>'
    +'<div><label style="font-size:11px;font-weight:700;color:#334155;display:block;margin-bottom:4px;">Registry Password</label><input id="r6p-build-regpass" type="password" style="padding:7px;border:1px solid #cbd5e1;border-radius:6px;font-size:12px;width:120px;"></div>'
    +'<button class="r6p-btn primary" onclick="r6pGenRealDockerfiles(false)" style="padding:8px 16px;font-size:12px;">&#9654; Build Containers</button>'
    +'</div>'
    +'<div style="background:#f8fafc;border:1px solid #e2e8f0;border-radius:8px;padding:10px 14px;margin-bottom:14px;">'
    +'<div style="font-size:11px;font-weight:700;color:#334155;margin-bottom:6px;">Build Mode</div>'
    +'<label style="font-size:12px;color:#334155;margin-right:16px;cursor:pointer;"><input type="radio" name="r6p-build-mode" value="manual" checked style="margin-right:6px;">Manual - review and click Run on each command</label>'
    +'<label style="font-size:12px;color:#334155;cursor:pointer;"><input type="radio" name="r6p-build-mode" value="auto" style="margin-right:6px;">Automatic - extract, build, scan and push run immediately after generation</label>'
    +'<div style="font-size:10px;color:#94a3b8;margin-top:4px;">Automatic mode pushes real images to the selected registry with no extra confirmation step - use Manual for a first run against a new registry.</div>'
    +'</div>'
    +'<div id="r6p-build-status" style="font-size:12px;font-weight:600;color:#64748b;margin-bottom:10px;line-height:1.7;"></div>'
    +'</div>'
    +r6pFoot(9);
  }
  if(n===10)return '<div style="display:flex;gap:8px;flex-wrap:wrap;margin-bottom:12px;"><button class="r6p-btn primary" onclick="r6pGenYAML()">Generate All YAML</button><button class="r6p-btn secondary" onclick="r6pGenHelm()">Helm Chart</button><button class="r6p-btn secondary" onclick="r6pGenKustomize()">Kustomize</button><button class="r6p-btn secondary" onclick="r6pGenFlux()">Flux</button></div><pre id="r6p-yaml-preview" style="background:#0f172a;color:#2dd4bf;border-radius:8px;padding:14px;font-size:11px;max-height:280px;overflow:auto;white-space:pre-wrap;min-height:60px;margin-bottom:14px;">-- Click Generate All YAML --</pre>'+r6pFoot(10);
  if(n===11)return '<div id="r6p-bundle-status" style="background:#f8fafc;border:1px solid #e2e8f0;border-radius:8px;padding:10px;margin-bottom:12px;font-size:12px;color:#64748b;">Generate bundle to see status.</div><pre id="r6p-bundle-preview" style="background:#0f172a;color:#c4b5fd;border-radius:8px;padding:14px;font-size:11px;max-height:220px;overflow:auto;white-space:pre-wrap;min-height:60px;margin-bottom:12px;">-- Generate bundle to see manifest --</pre>'+r6pFoot(11,'<button class="r6p-btn primary" onclick="r6pGenBundle()">Generate OpenCenter Bundle</button><button class="r6p-btn secondary" onclick="r6pDownloadBundle()">Download</button>');
  if(n===12){
    var isC=R6P.captureMethod==='compat';
    var bsName=(R6P.bs&&R6P.bs.name)||'your-business-system';
    var bsSlug=bsName.toLowerCase().replace(/\s+/g,'-').replace(/[^a-z0-9-]/g,'');
    var out=R6P.bundle||{};
    var pkg_defs=[
      {f:'opencenter_import_manifest.json',req:'Required',   note:'Main OpenCenter import descriptor'},
      {f:'k8s/',                            req:'Required',   note:'Kubernetes workload YAML'},
      {f:'helm/',                           req:'Required',   note:'Helm chart package'},
      {f:'kustomize/',                      req:'Required',   note:'Kustomize base and overlays'},
      {f:'flux/',                           req:'Required',   note:'Flux GitOps definitions'},
      {f:'Dockerfile',                      req:'Recommended',note:'Container build recipe'},
      {f:'image_build_plan.yaml',           req:'Required',   note:'Container image build and push plan'},
      {f:'app_capture_manifest.json',       req:'Required',   note:'Application content captured from snapshot'},
      {f:'externalization_plan.yaml',       req:'Required',   note:'Config, secrets, state, DB, PVC plan'},
      {f:'container_readiness_report.json', req:'Required',   note:'Machine-readable readiness report'},
      {f:'container_readiness_report.md',   req:'Recommended',note:'Human-readable readiness report'},
      {f:'compatibility_warnings.json',     req:'Conditional',note:isC?'Required for Full Snapshot mode':'Not required for Smart Snapshot'}
    ];
    var pkgRows=pkg_defs.map(function(p){
      var done=R6P.artifacts&&R6P.artifacts[p.f];
      var isOk=done||(R6P.yaml&&['k8s/','helm/','flux/','kustomize/','Dockerfile'].indexOf(p.f)>=0&&R6P.yaml.length>10);
      var isCond=p.req==='Conditional';
      var st=isCond?(isC?'Found':'Not Required'):isOk?'Found':'Missing';
      var sbg={Found:'#dcfce7','Not Required':'#f1f5f9',Missing:'#fee2e2'}[st]||'#fef3c7';
      var sfg={Found:'#16a34a','Not Required':'#64748b',Missing:'#dc2626'}[st]||'#d97706';
      var reqBg=p.req==='Required'?'#fee2e2':p.req==='Recommended'?'#fef3c7':'#f1f5f9';
      var reqFg=p.req==='Required'?'#dc2626':p.req==='Recommended'?'#d97706':'#64748b';
      return '<tr><td style="font-family:monospace;font-size:11px;font-weight:600;">'+p.f+'</td>'
        +'<td><span style="background:'+reqBg+';color:'+reqFg+';padding:2px 7px;border-radius:999px;font-size:10px;font-weight:700;">'+p.req+'</span></td>'
        +'<td><span style="background:'+sbg+';color:'+sfg+';padding:2px 8px;border-radius:999px;font-size:10px;font-weight:700;">'+st+'</span></td>'
        +'<td style="font-size:11px;color:#64748b;">'+p.note+'</td>'
        +'<td><button onclick="r6pPreviewArtifact(\''+p.f+'\')" style="background:#f1f5f9;color:#334155;border:1px solid #e2e8f0;border-radius:4px;padding:2px 8px;font-size:10px;cursor:pointer;">Preview</button></td></tr>';
    }).join('');

    var wloads=(out.workloads||[]).map(function(w){return w.name||w;}).join(', ')||'—';
    var extSvcs=(out.externalServices||[]).map(function(s){return s.name||s;}).join(', ')||'None';
    var warns=(out.warnings||[]).length;
    var validation=R6P._bundleValidated?'<div class="r6p-success-box">Bundle validated. Ready to send to OpenCenter.</div>':'<div style="background:#fef3c7;border:1px solid #f59e0b;border-radius:8px;padding:10px;font-size:12px;color:#92400e;margin-bottom:12px;">Run <strong>Validate Bundle</strong> before sending to OpenCenter.</div>';

    return (isC?'<div class="r6p-warn-box">COMPATIBILITY CONTAINER: Not fully cloud-native. Manual hardening required before production.</div>':'<div class="r6p-success-box">SMART SNAPSHOT CAPTURE: App content ready for OpenCenter import.</div>')

    /* ─── OpenCenter Managed Handoff panel ─── */
    +'<div style="background:#f0fdf4;border:2px solid #86efac;border-radius:10px;padding:16px;margin-bottom:16px;">'
    +'<div style="font-size:13px;font-weight:800;color:#166534;margin-bottom:6px;">OpenCenter Managed Handoff</div>'
    +'<p style="font-size:12px;color:#14532d;margin:0 0 10px;line-height:1.6;">This app bundle is ready to be imported by OpenCenter. OpenCenter manages GitOps and Kubernetes deployment automatically. No local <code>git push</code>, <code>kubectl</code>, or <code>flux</code> commands are needed.</p>'
    +'<div style="font-size:12px;color:#166534;font-weight:700;">Next: Click <em>Send to OpenCenter Import Stage</em> below to populate the OpenCenter import section.</div>'
    +'</div>'

    /* ─── Package Contents table ─── */
    +'<div style="font-weight:700;font-size:13px;color:#0f172a;margin-bottom:8px;">Package Contents</div>'
    +'<div style="overflow-x:auto;margin-bottom:16px;"><table class="r6p-table"><thead><tr><th>File / Folder</th><th>Required?</th><th>Status</th><th>Purpose</th><th>Action</th></tr></thead><tbody>'+pkgRows+'</tbody></table></div>'

    /* ─── Required Gate per component (Step 12 must not deploy a component unless its gate passes) ─── */
    +'<div style="font-weight:700;font-size:13px;color:#0f172a;margin-bottom:8px;">Required Gate Before Deployment</div>'
    +(!(R6P.components||[]).length?'':
    '<div style="overflow-x:auto;margin-bottom:16px;"><table class="r6p-table"><thead><tr><th>Component</th><th>UI Decision Badge</th><th>Required Gate</th></tr></thead><tbody>'
    +(R6P.components||[]).map(function(c){
      var saved=(R6P.targetForms&&R6P.targetForms[c.name])||r6pDecideTargetForm(c).form;
      var badge=r6pBadgeForTargetForm(saved);
      var gate=r6pRequiredGateFor(saved);
      return '<tr><td style="font-weight:600;">'+c.name+'</td><td><span style="background:'+badge[1]+'22;color:'+badge[1]+';padding:2px 8px;border-radius:999px;font-size:10px;font-weight:700;">'+badge[0]+'</span></td><td style="font-size:11px;color:#64748b;">'+gate+'</td></tr>';
    }).join('')
    +'</tbody></table></div>')

    /* ─── Bundle Summary ─── */
    +'<div style="background:#f8fafc;border:1px solid #e2e8f0;border-radius:8px;padding:14px;margin-bottom:16px;">'
    +'<div style="font-weight:700;font-size:13px;color:#0f172a;margin-bottom:10px;">Import Package Summary</div>'
    +'<div style="display:grid;grid-template-columns:repeat(3,1fr);gap:8px;font-size:12px;">'
    +'<div><div style="color:#64748b;font-size:10px;font-weight:700;text-transform:uppercase;margin-bottom:2px;">Business System</div><div style="font-weight:700;color:#0f172a;">'+bsName+'</div></div>'
    +'<div><div style="color:#64748b;font-size:10px;font-weight:700;text-transform:uppercase;margin-bottom:2px;">Source Platform</div><div style="font-weight:700;color:#0369a1;">FLEX</div></div>'
    +'<div><div style="color:#64748b;font-size:10px;font-weight:700;text-transform:uppercase;margin-bottom:2px;">Capture Method</div><div style="font-weight:700;color:'+(isC?'#7c3aed':'#16a34a')+';">'+(isC?'Full Snapshot Compatibility':'Smart Snapshot')+'</div></div>'
    +'<div><div style="color:#64748b;font-size:10px;font-weight:700;text-transform:uppercase;margin-bottom:2px;">Cloud-Native Status</div><div style="font-weight:700;color:'+(isC?'#7c3aed':'#16a34a')+';">'+(isC?'COMPATIBILITY_CONTAINER_ONLY':'CLOUD_NATIVE_READY')+'</div></div>'
    +'<div><div style="color:#64748b;font-size:10px;font-weight:700;text-transform:uppercase;margin-bottom:2px;">Workloads</div><div style="font-weight:700;color:#0f172a;">'+wloads+'</div></div>'
    +'<div><div style="color:#64748b;font-size:10px;font-weight:700;text-transform:uppercase;margin-bottom:2px;">External Services</div><div style="font-weight:700;color:#0f172a;">'+extSvcs+'</div></div>'
    +'<div><div style="color:#64748b;font-size:10px;font-weight:700;text-transform:uppercase;margin-bottom:2px;">Warnings</div><div style="font-weight:700;color:'+(warns?'#d97706':'#16a34a')+';">'+warns+'</div></div>'
    +'<div><div style="color:#64748b;font-size:10px;font-weight:700;text-transform:uppercase;margin-bottom:2px;">Import Status</div><div id="r6p-s12-status" style="font-weight:700;color:'+(R6P._bundleValidated?'#16a34a':'#d97706')+'">'+(R6P._bundleValidated?'Ready for Import':'Pending Validation')+'</div></div>'
    +'</div></div>'

    +validation

    +'<div class="r6p-stage-footer">'
    +'<button class="r6p-btn primary" onclick="r6pValidateBundle()">Validate Bundle</button>'
    +'<button class="r6p-btn success" id="r6p-send-oc-btn" onclick="r6pSendToOC()" style="'+(R6P._bundleValidated?'':'opacity:.5;cursor:not-allowed;')+'" '+(R6P._bundleValidated?'':'title="Validate bundle first"')+'>Send to OpenCenter Import Stage</button>'
    +'<button class="r6p-btn purple" onclick="r6pAutoDeployToOpenCenter()">&#9889; Deploy to Production GitOps Now (real git commit + push)</button>'
    +'<button class="r6p-btn secondary" onclick="r6pMarkDone(12)">Mark Complete</button>'
    +'</div>'
    +'<div id="r6p-auto-deploy-status" style="font-size:12px;font-weight:600;color:#64748b;margin-bottom:6px;"></div>'

    /* ─── Advanced Direct GitOps (hidden by default) ─── */
    +'<div style="margin-top:18px;border:1px dashed #cbd5e1;border-radius:8px;overflow:hidden;">'
    +'<div onclick="this.nextSibling.style.display=this.nextSibling.style.display===\'none\'?\'block\':\'none\'" style="padding:10px 14px;background:#f8fafc;cursor:pointer;display:flex;justify-content:space-between;align-items:center;">'
    +'<span style="font-size:12px;font-weight:700;color:#64748b;">Advanced Direct GitOps Mode</span>'
    +'<span style="font-size:10px;color:#94a3b8;">Click to expand</span></div>'
    +'<div style="display:none;padding:14px;">'
    +'<div style="background:#fef3c7;border:1px solid #f59e0b;border-radius:6px;padding:10px;font-size:12px;color:#92400e;margin-bottom:12px;">'
    +'<strong>Warning:</strong> Direct GitOps bypasses OpenCenter-managed deployment. Use only for development or troubleshooting.</div>'
    +r6pCmd('12-git-adv','BS_NAME="'+bsSlug+'"\n\n# Verify opencenter CLI\nif ! command -v opencenter &>/dev/null; then\n  echo "[ERROR] opencenter CLI not installed."\n  exit 127\nfi\n\nGITOPS_DIR=$(opencenter cluster describe '+(R6P.creds.opencenter.clusterRef||'rackspace-flex/flex-prod-k8s')+' 2>/dev/null | grep "git_dir:" | awk \'{print $2}\')\n\n[ -z "$GITOPS_DIR" ] && { echo "[ERROR] GITOPS_DIR empty. Run: opencenter cluster list"; exit 1; }\n\ngit -C "$GITOPS_DIR" add "applications/workloads/$BS_NAME"\ngit -C "$GITOPS_DIR" commit -m "Import R6 app bundle: $BS_NAME"\ngit -C "$GITOPS_DIR" push\ncommand -v flux &>/dev/null && flux reconcile kustomization flux-system --with-source || echo "[WARN] flux not installed"')
    +'</div></div>';
  }
  if(n===13){
    var comps13=(R6P.components||[]).filter(function(c){return c.tgt;});
    if(!comps13.length)return '<div class="r6p-warn-box">No components have a FLEX Target IP yet - go to Step 1, click Inspect on the selected system, and fill in Target IP for each component.</div>'+r6pFoot(13);
    var rows13=comps13.map(function(c){
      var d=r6pDecideMigrationMode(c);
      var isDb=d.workloadType.toLowerCase().indexOf('database')>=0;
      var dataCmd=isDb
        ?('# DB dump/restore\nssh -i ~/.ssh/id_rsa root@'+c.tgt+' "pg_dump -Fc '+ (c.name||'app').toLowerCase().replace(/\s+/g,'_')+' > /tmp/dbdump.dump || mysqldump --all-databases > /tmp/dbdump.sql"\nscp -i ~/.ssh/id_rsa root@'+c.tgt+':/tmp/dbdump.* ./\n# restore into target (Kubernetes DB / operator / managed DB) once provisioned')
        :('# App file / volume sync (rsync final delta before cutover)\nrsync -az --delete -e "ssh -i ~/.ssh/id_rsa -o StrictHostKeyChecking=no" root@'+c.tgt+':/opt/ /opt/app/ ./final-sync/'+(c.name||'app').toLowerCase().replace(/\s+/g,'_')+'/');
      var validateCmd='# App-level validation\n'
        +'ssh -i ~/.ssh/id_rsa -o StrictHostKeyChecking=no root@'+c.tgt+' "curl -s -o /dev/null -w \'HTTP %{http_code}\\n\' http://localhost'+(c.path&&c.path.indexOf('/')===0?c.path:'/health')+'"\n'
        +(isDb?'ssh -i ~/.ssh/id_rsa root@'+c.tgt+' "echo \''+(c.path||'SELECT 1')+'\' | psql -U postgres || mysql -e \''+(c.path||'SELECT 1')+'\'"':'echo "compare response time / error rate against source VM baseline"');
      return '<div style="border:1px solid #e2e8f0;border-radius:8px;padding:12px;margin-bottom:10px;">'
        +'<div style="font-weight:800;font-size:13px;color:#0f172a;margin-bottom:2px;">'+c.name+' <span style="font-size:10px;font-weight:400;color:#64748b;">('+d.method+')</span></div>'
        +'<div style="font-size:10px;font-weight:700;color:#64748b;margin:8px 0 4px;">DATA MIGRATION</div>'+r6pCmd('13-data-'+c.name.replace(/\W+/g,''),dataCmd)
        +'<div style="font-size:10px;font-weight:700;color:#64748b;margin:8px 0 4px;">APP-LEVEL VALIDATION</div>'+r6pCmd('13-val-'+c.name.replace(/\W+/g,''),validateCmd)
        +'</div>';
    }).join('');
    var cutover='# Cutover checklist (run in order)\n'
      +'# 1. Lower DNS TTL to 60s, at least 24h before cutover\n'
      +'# 2. Freeze writes on source FLEX VM(s)\n'
      +'openstack security group rule create --protocol tcp --dst-port 1-65535 --ingress SOURCE_SG --remote-ip 0.0.0.0/0 --disable  # example freeze pattern, adjust to real SG\n'
      +'# 3. Final data sync (re-run the rsync/dump commands above)\n'
      +'# 4. Confirm target app pods healthy: kubectl get pods -n '+((R6P.bs&&R6P.bs.name)||'app').toLowerCase().replace(/\s+/g,'-')+'\n'
      +'# 5. Run smoke tests (re-run the validation commands above against the target)\n'
      +'# 6. Switch DNS/Octavia LB/Gateway to target\n'
      +'openstack loadbalancer member create --address <TARGET_POD_IP> --protocol-port 80 <LISTENER_POOL_ID>\n'
      +'# 7. Monitor 24-48h\n'
      +'# 8. Rollback path: revert DNS/LB to source VM if error rate/latency regress';
    var nsSlug=((R6P.bs&&R6P.bs.name)||'app').toLowerCase().replace(/[^a-z0-9]+/g,'-').replace(/^-+|-+$/g,'');
    var uatRows=(R6P.components||[]).map(function(c){
      var dtMeta=r6pUatDeviceMeta(c);
      var form=(R6P.targetForms&&R6P.targetForms[c.name])||r6pDecideTargetForm(c).form;
      var compSlug=(c.name||'app').toLowerCase().replace(/[^a-z0-9]+/g,'-').replace(/^-+|-+$/g,'');
      var healthPath=(c.path&&c.path.indexOf('/')===0)?c.path.split(',')[0]:'/health';
      var isContainerized=(form==='CONTAINERIZED'||form==='PARTIALLY_CONTAINERIZED');
      var isVm=(form==='RETAINED_FLEX_VM'||form==='REDEPLOYED_FLEX_VM');
      var isOperator=(form==='OPERATOR_MANAGED'||form==='KUBERNETES_NATIVE');
      var uatCmd;
      if(isContainerized){
        uatCmd='# Confirm pods are Running/Ready in the target namespace\n'
          +'kubectl get pods -n '+nsSlug+' -l app='+compSlug+' -o wide\n'
          +'# Hit the real health endpoint inside the deployed pod (post-migration target, not the source VM)\n'
          +'kubectl exec -n '+nsSlug+' deploy/'+compSlug+' -- sh -c "curl -fsS -o /dev/null -w \'HTTP %{http_code}\\n\' http://localhost:8080'+healthPath+'" || echo "UAT FAILED: '+c.name+' health check did not return 2xx"';
      } else if(isVm&&c.tgt){
        uatCmd='# Confirm the retained/redeployed FLEX VM is reachable and healthy post-migration\n'
          +'ssh -i ~/.ssh/id_rsa -o StrictHostKeyChecking=no root@'+c.tgt+' "curl -fsS -o /dev/null -w \'HTTP %{http_code}\\n\' http://localhost'+healthPath+'" || echo "UAT FAILED: '+c.name+' health check did not return 2xx"';
      } else if(isOperator){
        uatCmd='# Confirm the operator-managed / Kubernetes-native resource is ready\n'
          +'kubectl get pods,svc -n '+nsSlug+' -l app='+compSlug+'\n'
          +'kubectl exec -n '+nsSlug+' deploy/'+compSlug+' -- sh -c "true" 2>/dev/null && echo "'+compSlug+' pod reachable" || echo "UAT NEEDS REVIEW: confirm '+c.name+' operator status manually"';
      } else {
        uatCmd='# '+c.name+' ('+form+') has no in-cluster/VM endpoint to smoke-test automatically - confirm manually per its connectivity plan.';
      }
      return '<div style="border:1px solid #e2e8f0;border-radius:8px;padding:12px;margin-bottom:10px;">'
        +'<div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:2px;">'
        +'<div style="display:flex;align-items:center;gap:8px;">'
        +'<span style="width:24px;height:24px;border-radius:6px;background:'+dtMeta.color+';color:#fff;display:inline-flex;align-items:center;justify-content:center;font-size:12px;flex-shrink:0;" title="'+dtMeta.label+'">'+dtMeta.icon+'</span>'
        +'<div><div style="font-weight:800;font-size:13px;color:#0f172a;">'+c.name+'</div><div style="font-size:10px;color:#64748b;">'+dtMeta.label+'</div></div>'
        +'</div>'
        +'<span style="background:#eff6ff;color:#0369a1;padding:2px 8px;border-radius:999px;font-size:10px;font-weight:700;">'+form+'</span></div>'
        +r6pCmd('13-uat-'+c.name.replace(/\W+/g,''),uatCmd)
        +'<button onclick="r6pOpenMobileBench(\''+c.name.replace(/'/g,"\\'")+'\')" style="margin-top:8px;background:#eff6ff;color:#1d4ed8;border:1px solid #bfdbfe;border-radius:6px;padding:5px 10px;font-size:11px;font-weight:700;cursor:pointer;">'+dtMeta.icon+' Load in R6 Phone Preview</button>'
        +'</div>';
    }).join('');
    return '<div class="r6p-info-box">Real per-component data migration and validation commands, plus a cutover checklist with real OpenStack/Kubernetes commands (edit IDs/SGs for your environment).</div>'
      +rows13
      +'<div style="font-weight:800;font-size:13px;color:#0f172a;margin:14px 0 4px;">Cutover</div>'+r6pCmd('13-cutover',cutover)
      +'<div style="font-weight:800;font-size:14px;color:#0f172a;margin:20px 0 4px;">UAT: Verify Every Migrated Component Is Actually Working</div>'
      +'<div class="r6p-info-box">Runs after OpenCenter production deployment (Step 12). Tests the real post-migration target - the deployed Kubernetes pod for containerized/operator-managed components, the retained/redeployed VM for VM-targeted components - not the old source VM. Click Run on each row, or Run All below.</div>'
      +uatRows
      +'<div style="display:flex;gap:8px;align-items:center;margin-top:6px;">'
      +'<button class="r6p-btn success" onclick="r6pMarkUatSignoff()">&#10003; UAT Sign-off: All Migrated Apps Verified Working</button>'
      +'<span id="r6p-uat-signoff-status" style="font-size:12px;font-weight:700;color:'+(R6P.uatSignedOff?'#16a34a':'#94a3b8')+';">'+(R6P.uatSignedOff?'Signed off '+R6P.uatSignedOff:'Not signed off yet')+'</span>'
      +'</div>'
      +r6pHandoverSection()
      +r6pFoot(13);
  }
  if(n===14){
    var comps14=R6P.components||[];
    var decisions14=comps14.map(function(c){return r6pDecideMigrationMode(c);});
    return '<div class="r6p-info-box">Generates the customer migration evidence report from everything captured in this session: source/target mapping, decisions, validation commands, artifacts.</div>'
      +'<button class="r6p-btn primary" onclick="r6pGenReport()" style="padding:8px 16px;font-size:12px;margin-bottom:12px;">&#9654; Generate Report</button>'
      +'<pre id="r6p-report-preview" style="background:#0f172a;color:#2dd4bf;border-radius:8px;padding:14px;font-size:11px;max-height:320px;overflow:auto;white-space:pre-wrap;">-- Click Generate Report --</pre>'
      +r6pFoot(14);
  }
  return '<p style="color:#94a3b8;">Stage '+n+'</p>';
};
window.r6pGenReport=function(){
  var comps=R6P.components||[];
  var decisions=comps.map(function(c){return r6pDecideMigrationMode(c);});
  var report={
    generatedAt:new Date().toISOString(),
    businessSystem:(R6P.bs&&R6P.bs.name)||'',
    sourcePlatform:'flex',
    targetCluster:R6P.creds.opencenter.clusterRef||'',
    componentMapping:comps.map(function(c){return {name:c.name,sourceIp:c.src||'',targetIp:c.tgt||'',healthOrQueryPath:c.path||''};}),
    migrationDecisions:decisions,
    captureMethod:R6P.captureMethod||'smart',
    bundle:R6P.bundle?{status:R6P.bundle.status,bundlePath:R6P.bundle.bundlePath,packageContents:R6P.bundle.packageContents}:null,
    realBundle:R6P._realBundle?{bundle_dir:R6P._realBundle.bundle_dir,imported_to:R6P._realBundle.imported_to,pull_secret:R6P._realBundle.pull_secret}:null,
    dependencyScans:R6P.depScan?Object.keys(R6P.depScan):[],
    warnings:(R6P.bundle&&R6P.bundle.warnings)||[],
    blockers:(R6P.bundle&&R6P.bundle.blockers)||[]
  };
  var pre=document.getElementById('r6p-report-preview');
  if(pre)pre.textContent=JSON.stringify(report,null,2);
  var blob=new Blob([JSON.stringify(report,null,2)],{type:'application/json'});
  var a=document.createElement('a');a.href=URL.createObjectURL(blob);
  a.download='migration_report_'+(report.businessSystem||'app').replace(/\s+/g,'_')+'.json';
  document.body.appendChild(a);a.click();document.body.removeChild(a);
  r6pMarkDone(14);
};

window.r6pMarkDone=function(n){R6P.status[n]='done';var badge=document.getElementById('r6p-stage-badge-'+n);if(badge){badge.textContent='Complete';badge.style.cssText='background:#dcfce7;color:#16a34a;padding:3px 12px;border-radius:999px;font-size:11px;font-weight:700;';}var card=document.getElementById('r6p-stage-'+n);if(card)card.className='r6p-stage done';var done=R6P_STEPS.filter(function(s){return R6P.status[s.n]==='done';}).length;var pct=Math.round(done/R6P_STEPS.length*100);var fill=document.getElementById('r6p-fill');if(fill)fill.style.width=pct+'%';var pEl=document.getElementById('r6p-pct');if(pEl)pEl.textContent=pct+'%';r6pRenderProgress();var nextN=r6pAdjacentStep(n,1);if(nextN!==undefined)r6pGoTo(nextN);};

window.r6pNext=function(){var n=r6pAdjacentStep(R6P.current,1);if(n!==undefined)r6pGoTo(n);};
window.r6pPrev=function(){var n=r6pAdjacentStep(R6P.current,-1);if(n!==undefined)r6pGoTo(n);};

window.r6pSetMethod=function(m){
  var box=document.getElementById('r6p-compat-confirm-box');
  var banner=document.getElementById('r6p-compat-banner');
  var sm=document.getElementById('r6p-sum-method');
  var cards=document.querySelectorAll('.r6p-method-card');
  if(m==='compat'){
    if(box)box.style.display='block';
    cards.forEach(function(c){c.classList.toggle('selected',c.classList.contains('compat'));});
    return;
  }
  R6P.captureMethod='smart';
  if(box)box.style.display='none';
  if(banner)banner.style.display='none';
  if(sm){sm.textContent='Smart Snapshot';sm.style.color='#38bdf8';}
  cards.forEach(function(c){c.classList.toggle('selected',!c.classList.contains('compat'));});
};
window.r6pConfirmCompat=function(){
  R6P.captureMethod='compat';R6P.compatConfirmed=true;
  var box=document.getElementById('r6p-compat-confirm-box');
  var banner=document.getElementById('r6p-compat-banner');
  var sm=document.getElementById('r6p-sum-method');
  var cards=document.querySelectorAll('.r6p-method-card');
  if(box)box.style.display='none';
  if(banner)banner.style.display='block';
  if(sm){sm.textContent='Full Snapshot';sm.style.color='#a78bfa';}
  cards.forEach(function(c){c.classList.toggle('selected',c.classList.contains('compat'));});
};;

window.r6pOpenSourceValidationStage=function(event){
  if(event){event.preventDefault();event.stopPropagation();}
  var button=document.querySelector('.stage-btn[data-stage="s4"]');
  if(button)button.click();else if(typeof window.activateStage==='function')window.activateStage('s4');
  setTimeout(function(){var source=document.getElementById('uatS1FlexVmSection')||document.getElementById('panel-s4');if(source&&source.scrollIntoView)source.scrollIntoView({behavior:'smooth',block:'start'});},180);
  return false;
};
window.r6pDecorateBusinessSystemProvenance=function(list,systems){
  (systems||[]).forEach(function(system){
    if(system.name!=='Automatic Business System from Existing VMs')return;
    var card=document.getElementById('r6p-bsc-'+system.id);if(!card||!card.firstElementChild)return;
    var note=document.createElement('div');note.className='r6p-bs-provenance';
    note.style.cssText='margin:-3px 0 9px 40px;font-size:11px;color:#636366;line-height:1.35;';
    note.innerHTML='Comes from the main migration pipeline\u2019s <a href="?stage=s4" onclick="return r6pOpenSourceValidationStage(event)" style="color:#0066cc;font-weight:700;text-decoration:underline;text-underline-offset:2px;">Stage 3 \u2014 Validation &amp; UAT</a>.';
    card.firstElementChild.insertAdjacentElement('afterend',note);
  });
};

window.r6pLoadBiz=function(){var list=document.getElementById('r6p-biz-list');if(!list)return;try{var sys=JSON.parse(localStorage.getItem('uatS1_systems')||'[]');if(!sys.length){list.innerHTML='<div style="text-align:center;padding:24px 10px;">'+'<div style="color:#94a3b8;font-size:13px;margin-bottom:12px;">No business systems yet. Create one right here - no need to leave R6.</div>'+'<button class="r6p-btn primary" onclick="typeof uatS1OpenModal===\'function\'&&uatS1OpenModal(null,\'custom\')" style="padding:8px 18px;font-size:12px;">+ Create New Business System</button>'+'</div>';return;}list.innerHTML=sys.map(function(s){var comps=s.components||[];var isSel=R6P.bs&&R6P.bs.id===s.id;var selBtn=isSel?'<button onclick="event.stopPropagation();" class="r6p-btn" style="padding:5px 12px;font-size:11px;background:#16a34a;color:#fff;border:1px solid #15803d;cursor:default;">&#10003; Selected</button>':'<button onclick="event.stopPropagation();r6pSelectBS(\''+s.id+'\')" class="r6p-btn primary" style="padding:5px 12px;font-size:11px;">Select for Refactor</button>';return '<div class="r6p-bs-card" id="r6p-bsc-'+s.id+'" onclick="r6pSelectBS(\''+s.id+'\')">'+'<div style="display:flex;justify-content:space-between;align-items:flex-start;margin-bottom:8px;">'+'<div style="display:flex;align-items:center;gap:8px;">'+'<div style="width:32px;height:32px;border-radius:8px;background:#eff6ff;color:#2563eb;font-weight:900;font-size:11px;display:grid;place-items:center;">'+s.name.slice(0,2).toUpperCase()+'</div>'+'<div><div style="font-weight:800;color:#0f172a;font-size:14px;">'+s.name+'</div><div style="font-size:11px;color:#64748b;">'+(s.type||'')+(s.criticality?' - '+s.criticality:'')+(s.migrationWave?' - Wave '+s.migrationWave:'')+'</div></div></div>'+(s.region?'<span style="background:#eff6ff;color:#2563eb;border:1px solid #bfdbfe;border-radius:999px;padding:2px 8px;font-size:10px;font-weight:700;margin-right:6px;">&#127760; '+s.region+'</span>':'')+'<span style="background:#dcfce7;color:#16a34a;padding:2px 8px;border-radius:999px;font-size:10px;font-weight:700;">Active</span></div>'+'<div style="display:flex;flex-wrap:wrap;gap:3px;margin-bottom:10px;">'+comps.slice(0,7).map(function(c){var cls=r6pClassifyFor(c.name);var dot=cls.state==='Stateless'?'#16a34a':cls.state==='Stateful'?'#dc2626':'#d97706';return '<span class="r6p-chip" title="'+cls.state+' - '+cls.decision.replace(/"/g,'&quot;')+'"><span style="display:inline-block;width:6px;height:6px;border-radius:50%;background:'+dot+';margin-right:4px;"></span>'+c.name+'</span>';}).join('')+'</div>'+'<div style="display:flex;gap:6px;">'+selBtn+'<button onclick="event.stopPropagation();typeof uatS1OpenModal===\'function\'&&uatS1OpenModal(\''+s.id+'\')" class="r6p-btn secondary" style="padding:5px 12px;font-size:11px;">Inspect</button><button onclick="event.stopPropagation();r6pDeleteBS(\''+s.id+'\',\''+s.name.replace(/'/g,"\\'")+'\')" style="background:#fee2e2;color:#dc2626;border:1px solid #fecaca;border-radius:6px;padding:5px 12px;font-size:11px;font-weight:700;cursor:pointer;margin-left:auto;">&#128465; Delete</button></div></div>';}).join('');r6pDecorateBusinessSystemProvenance(list,sys);var ag=document.getElementById('r6p-arch-grid'),lg=document.getElementById('uatS1ArchList');if(ag&&lg&&lg.innerHTML.trim()){ag.innerHTML=lg.innerHTML;ag.querySelectorAll('.uat-s1-arch-card').forEach(function(c){c.style.cursor='pointer';c.addEventListener('click',function(){ag.querySelectorAll('.uat-s1-arch-card').forEach(function(x){x.classList.remove('selected');});c.classList.add('selected');var k=c.getAttribute('data-arch-key');typeof window.uatS1OpenModal==='function'&&window.uatS1OpenModal(null,k);});});}}catch(e){if(list)list.innerHTML='<div style="color:#dc2626;padding:10px;">'+e.message+'</div>';}};

window.r6pMarkStep1Selected=function(){
  R6P.status[1]='done';
  var badge=document.getElementById('r6p-stage-badge-1');
  if(badge){badge.textContent='Complete';badge.style.cssText='background:#dcfce7;color:#16a34a;padding:3px 12px;border-radius:999px;font-size:11px;font-weight:700;';}
  var done=Object.values(R6P.status).filter(function(s){return s==='done';}).length;
  var pct=Math.round(done/(R6P_MAX_STEP+1)*100);
  var fill=document.getElementById('r6p-fill');if(fill)fill.style.width=pct+'%';
  var pEl=document.getElementById('r6p-pct');if(pEl)pEl.textContent=pct+'%';
  r6pRenderProgress();
};
window.r6pSelectBS=function(id){document.querySelectorAll('[id^="r6p-bsc-"]').forEach(function(el){el.classList.remove('selected');});var c=document.getElementById('r6p-bsc-'+id);if(c)c.classList.add('selected');try{var raw=localStorage.getItem('uatS1_systems')||'[]';var sys=JSON.parse(raw);var bs=sys.find(function(s){return s.id===id;});if(!bs)return;localStorage.setItem(R6P_SELECTED_BS_KEY,String(bs.id));R6P_BS_STORAGE_SIG=raw;R6P.bs=bs;R6P.components=bs.components||[];R6P.scanRunId=null;R6P.structuredAppraisal=null;R6P.appraisalReviewed=false;var si=document.getElementById('r6p-sum-input');if(si)si.textContent=bs.name;var sc=document.getElementById('r6p-sum-comps');if(sc)sc.textContent=(bs.components||[]).length+' components';r6pMarkStep1Selected();r6pLoadBiz();if(typeof r6pRenderContainerReadyForm==='function')r6pRenderContainerReadyForm();if(typeof r6pRefreshComponentDrivenStages==='function')r6pRefreshComponentDrivenStages();r6pRestoreScanRun();}catch(e){}};
window.r6pDeleteBS=function(id,name){
  if(!confirm('Delete business system "'+name+'"? This removes it from Migration Logs everywhere, not just here.'))return;
  try{
    var sys=JSON.parse(localStorage.getItem('uatS1_systems')||'[]');
    sys=sys.filter(function(s){return s.id!==id;});
    localStorage.setItem('uatS1_systems',JSON.stringify(sys));
    if(window.UAT)window.UAT.businessSystems=sys;
    if(R6P.bs&&R6P.bs.id===id){R6P.bs=null;R6P.components=[];localStorage.removeItem(R6P_SELECTED_BS_KEY);}
    r6pBusinessSystemsChanged();
  }catch(e){alert('Delete failed: '+e.message);}
};

window.r6pRunCmd=function(cmdId,outId){var out=document.getElementById(outId),cEl=document.getElementById(cmdId);if(!out||!cEl)return;var cmd=cEl.textContent.trim();out.style.display='block';out.style.borderColor='#134e4a';out.textContent='$ '+cmd+'\n';var url='/api/stream/run-cmd?cmd='+encodeURIComponent(cmd);var es=new EventSource(url);es.onmessage=function(e){if(e.data!=='[DONE]'){out.textContent+=e.data+'\n';out.scrollTop=out.scrollHeight;if(e.data.indexOf('[EXIT 0]')>=0)out.style.borderColor='#166534';}else{es.close();if((out.textContent.indexOf('EXIT 127')>=0||out.textContent.indexOf('command not found')>=0)&&R6ACE_INSTALL&&R6ACE_INSTALL[cmd]){out.style.borderColor='#dc2626';var iid='inst-'+cmdId;if(!document.getElementById(iid)){var ic=R6ACE_INSTALL[cmd];var d=document.createElement('div');d.id=iid;d.style.cssText='margin-top:8px;background:#fff3cd;border:2px solid #f59e0b;border-radius:8px;padding:12px;';d.innerHTML='<strong style="color:#92400e;">Not installed</strong><pre style="background:#0f172a;color:#fbbf24;border-radius:4px;padding:6px;font-size:10px;white-space:pre-wrap;margin:6px 0;">'+ic+'</pre><button onclick="r6aceRunInstall(\''+iid+'\',\''+cmdId+'\',\''+outId+'\')" style="background:#16a34a;color:#fff;border:none;border-radius:6px;padding:6px 14px;font-size:11px;font-weight:800;cursor:pointer;">Install Now</button>';out.parentNode.insertBefore(d,out.nextSibling);}}}};es.onerror=function(){out.textContent+='[closed]\n';es.close();};};
window.r6aceRun=window.r6pRunCmd;

window.r6pGenYAML=function(){var comps=R6P.components.length?R6P.components:[{name:'app',type:'frontend',ports:['8080']}];R6P.yaml=comps.map(function(c){var role=(c.type||c.role||'frontend').toLowerCase();var n=(c.name||'app').toLowerCase().replace(/\s+/g,'-').replace(/[^a-z0-9-]/g,'');if(role==='database'||role==='db')return '# ExternalDB: '+n+'\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: '+n+'-db-config\ndata:\n  host: "REPLACE_WITH_DB_HOST"\n  port: "5432"\n';return 'apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: '+n+'\nspec:\n  replicas: 2\n  selector:\n    matchLabels:\n      app: '+n+'\n  template:\n    metadata:\n      labels:\n        app: '+n+'\n    spec:\n      containers:\n      - name: '+n+'\n        image: registry.example.com/'+n+':v1.0.0\n        ports:\n        - containerPort: '+(c.ports&&c.ports[0]||8080)+'\n---\napiVersion: v1\nkind: Service\nmetadata:\n  name: '+n+'\nspec:\n  selector:\n    app: '+n+'\n  ports:\n  - port: 80\n    targetPort: '+(c.ports&&c.ports[0]||8080)+'\n';}).join('\n---\n');var el=document.getElementById('r6p-yaml-preview');if(el)el.textContent=R6P.yaml;};
window.r6pGenHelm=function(){var n=((R6P.bs&&R6P.bs.name)||'app').toLowerCase().replace(/\s+/g,'-');var el=document.getElementById('r6p-yaml-preview');if(el)el.textContent='# Chart.yaml\napiVersion: v2\nname: '+n+'\nversion: 1.0.0\n\n# values.yaml\nreplicaCount: 2\nimage:\n  repository: registry.example.com/'+n+'\n  tag: v1.0.0\n';};
window.r6pGenKustomize=function(){var el=document.getElementById('r6p-yaml-preview');if(el)el.textContent='# kustomization.yaml\napiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n- namespace.yaml\n- deployment.yaml\n- service.yaml\n- configmap.yaml\n- ingress.yaml\noverlays: dev/ uat/ prod/\n';};
/* Real Flux Kustomization generation - calls the same production /api/r6/generate-bundle
   endpoint Step 9/12 use, with import_to_gitops:false so this preview never writes to a
   real GitOps repo or runs git commands. Replaces the old client-side-only hardcoded
   string preview, which never reflected real dependsOn, real paths, or real validation. */
window.r6pGenFlux=function(){
  var el=document.getElementById('r6p-yaml-preview');
  if(!R6P.components||!R6P.components.length){if(el)el.textContent='Select a Business System in Step 1 first.';return;}
  var clusterRef=(R6P.creds.opencenter.clusterRef||'rackspace-flex/flex-prod-k8s').split('/');
  var org=clusterRef[0]||'rackspace-flex',cluster=clusterRef[1]||'flex-prod-k8s';
  var comps=R6P.components.filter(function(c){return c.tgt;});
  var srcComp=comps[0];
  var workloads=comps.map(function(c){
    var form=(R6P.targetForms&&R6P.targetForms[c.name])||r6pDecideTargetForm(c).form;
    var buildable=(form==='CONTAINERIZED'||form==='PARTIALLY_CONTAINERIZED');
    var startCmd=(R6P.startCmdOverride&&R6P.startCmdOverride[c.name])||r6pDetectStartCommand(c);
    var siblingDeps=(R6P.components||[]).filter(function(x){return x.name!==c.name;}).map(function(x){return x.name;});
    var endpoint=r6pParseTargetEndpoint(c.tgt);
    return {component:c.name,image:'debian:stable-slim',replicas:1,
      readiness:buildable?'READY':'KEEP_ON_VM_FOR_NOW',layer:'API',sourcePath:c.path||'/opt/app',targetForm:form,
      startCommand:startCmd,healthPath:(c.path&&c.path.indexOf('/')===0)?c.path.split(',')[0]:'/health',
      dependencies:siblingDeps,targetIp:endpoint.ip,targetPort:endpoint.port,
      persistentPath:r6pPersistentPathFor(c)};
  });
  var payload={org:org,cluster:cluster,region:stage9Region,cloud:cloudCreds,
    registry:{type:'harbor',project:'flex-apps'},
    source_vm:{host:(srcComp&&srcComp.tgt)||'',user:'root'},
    auto_commit:false,import_to_gitops:false,
    bundle:{id:'r6p-flux-preview-'+Date.now(),businessSystemName:(R6P.bs&&R6P.bs.name)||'app',workloads:workloads}};
  if(el){el.textContent='Generating real Flux Kustomization via the backend...';el.style.color='';}
  fetch('/api/r6/generate-bundle',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)})
    .then(function(r){return r.json();})
    .then(function(d){
      if(!el)return;
      if(!d||!d.ok){el.textContent='Flux generation failed: '+((d&&d.error)||'unknown error');el.style.color='#f87171';return;}
      var bv=d.bundle_validation||{};
      var evidence=['# Real Flux Kustomization - generated by /api/r6/generate-bundle (not a static preview)',
        '# Files written: '+((d.files||[]).length)+' | Output path: '+d.bundle_dir,
        '# Flux status: '+d.flux_status,
        '# Bundle validation: '+bv.status+' (blockers: '+((bv.blockers||[]).length)+', warnings: '+((bv.warnings||[]).length)+')'];
      (bv.blockers||[]).forEach(function(b){evidence.push('#   BLOCKER: '+b);});
      (bv.warnings||[]).forEach(function(w){evidence.push('#   warning: '+w);});
      evidence.push('',d.flux_yaml||'');
      el.textContent=evidence.join('\n');
      el.style.color=bv.status==='BLOCKED'?'#f87171':'';
    })
    .catch(function(e){if(el){el.textContent='Flux generation failed: '+e;el.style.color='#f87171';}});
};

/* Chains two streamed shell commands (extract, then build+push) into one terminal box.
   Reuses the same real /api/stream/run-cmd mechanism as every other Run button in R6 -
   no new backend execution path, just sequencing on the client. Used by Automatic mode;
   Manual mode instead renders two independent r6pCmd() boxes the operator clicks Run on. */
window.r6pAutoRunBuildPipeline=function(extractCmd,buildCmd,outId){
  var out=document.getElementById(outId);if(!out)return;
  out.style.display='block';out.style.borderColor='#134e4a';out.textContent='$ '+extractCmd+'\n';
  var extractOk=false;
  var es1=new EventSource('/api/stream/run-cmd?cmd='+encodeURIComponent(extractCmd));
  es1.onmessage=function(e){
    if(e.data!=='[DONE]'){
      out.textContent+=e.data+'\n';out.scrollTop=out.scrollHeight;
      if(e.data.indexOf('[EXIT 0]')>=0)extractOk=true;
    } else {
      es1.close();
      if(!extractOk){out.textContent+='\n[Automatic mode stopped: asset extraction failed - build/push skipped]\n';out.style.borderColor='#dc2626';return;}
      out.textContent+='\n$ '+buildCmd+'\n';
      var es2=new EventSource('/api/stream/run-cmd?cmd='+encodeURIComponent(buildCmd));
      var buildOk=false;
      es2.onmessage=function(e2){
        if(e2.data!=='[DONE]'){out.textContent+=e2.data+'\n';out.scrollTop=out.scrollHeight;if(e2.data.indexOf('[EXIT 0]')>=0){out.style.borderColor='#166534';buildOk=true;}}
        else{
          es2.close();
          if(buildOk&&typeof r6pAutoDeployToOpenCenter==='function'){
            out.textContent+='\n[Automatic mode: build+push done - deploying to production GitOps now]\n';
            r6pAutoDeployToOpenCenter();
          }
        }
      };
      es2.onerror=function(){out.textContent+='[closed]\n';es2.close();};
    }
  };
  es1.onerror=function(){out.textContent+='[closed]\n';es1.close();};
};
/* Real start-command detection: parses the actual `ps aux --sort=-%mem` output captured
   by Live Scan (Step 3) - not a guess. Picks the heaviest process that is not the SSH
   session, shell or scan tooling itself. Returns '' (not a fake command) when no scan has
   been run, so the backend emits a loud, fail-fast placeholder instead of something wrong. */
/* Parses a real component target endpoint (e.g. "mysql://50.56.158.30:3306",
   "http://FLEX-IP:80", a bare IP, or empty/placeholder) into {ip, port}. Only returns a
   real ip when it looks like an actual IPv4 address - the "FLEX-IP"/"OSPC-IP" placeholder
   values used before Step 1 Inspect is filled in never get treated as a resolvable address. */
window.r6pParseTargetEndpoint=function(tgt){
  var s=(tgt||'').trim();
  var m=s.match(/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\/([^:\/]+)(?::(\d+))?/)||s.match(/^([^:\/]+)(?::(\d+))?$/);
  var host=m?m[1]:'',port=m&&m[2]?parseInt(m[2],10):null;
  var isRealIp=/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(host);
  return {ip:isRealIp?host:'',port:port};
};
window.r6pDetectStartCommand=function(c){
  var scan=R6P.depScan&&R6P.depScan[c.name];
  if(!scan||!scan.rawLog)return '';
  var lines=scan.rawLog.split('\n');
  var start=-1,end=lines.length;
  for(var i=0;i<lines.length;i++){
    if(start<0&&/top processes/i.test(lines[i])){start=i+1;continue;}
    if(start>=0&&i>start&&/^--\s/.test(lines[i].trim())){end=i;break;}
  }
  if(start<0)return '';
  var noise=/^(ps|ssh|sshd:?|bash|sh|-bash|systemd|\[.*\]|init|cron|dbus|rsyslog|agetty|login|command)$/i;
  for(var j=start;j<end;j++){
    var parts=lines[j].trim().split(/\s+/);
    if(parts.length<11)continue;
    if(/^user$/i.test(parts[0])&&/^pid$/i.test(parts[1]))continue; // ps aux header row
    var cmd=parts.slice(10).join(' ');
    var bin=(cmd.split(/\s+/)[0]||'').split('/').pop();
    if(!bin||noise.test(bin))continue;
    return cmd;
  }
  return '';
};
window.r6pStage8ApprovedForCapture=function(){return !!(R6P.status&&R6P.status[8]==='done');};
window.r6pStage9DecisionFor=function(c){return (R6P.targetForms&&R6P.targetForms[c.name])||r6pDecideTargetForm(c).form;};
window.r6pStage9IsDatabaseLike=function(c){
  var form=r6pStage9DecisionFor(c);
  var txt=[c.name,c.type,c.category,c.role,c.runtime,c.product,c.tgt,c.path].join(' ').toLowerCase();
  return form==='DATA_MIGRATION_REQUIRED'||txt.indexOf('database')>=0||txt.indexOf('postgres')>=0||txt.indexOf('mysql')>=0||txt.indexOf('mariadb')>=0||txt.indexOf('mongodb')>=0||txt.indexOf('/var/lib/postgresql')>=0||txt.indexOf('/var/lib/mysql')>=0;
};
window.r6pIsContainerCaptureTarget=function(c){
  var form=r6pStage9DecisionFor(c);
  return (form==='CONTAINERIZED'||form==='PARTIALLY_CONTAINERIZED')&&!r6pStage9IsDatabaseLike(c);
};
window.r6pStage9ApprovedContainerTargets=function(){return (R6P.components||[]).filter(function(c){return r6pIsContainerCaptureTarget(c);});};
window.r6pBuildCaptureRows=function(){
  var rows=(R6P.components||[]).map(function(c){
    var form=r6pStage9DecisionFor(c);
    var endpoint=r6pParseTargetEndpoint(c.tgt);
    var approved=r6pIsContainerCaptureTarget(c);
    var cap=(R6P.captureRun&&R6P.captureRun.components||[]).filter(function(x){return x.component===c.name;})[0]||{};
    return {
      component:c.name,
      vm:endpoint.ip||c.tgt||'Not mapped',
      decision:form,
      snapshot:cap.snapshotStatus||(approved?'Pending':'Not applicable'),
      snapshotIds:cap.snapshotIds||[],
      simulated:false,
      extraction:cap.extractionStatus||(approved?'Waiting':'N/A'),
      build:cap.buildStatus||(approved?'Waiting':'N/A'),
      approved:approved,
      reason:cap.reason||''
    };
  });
  if(!rows.length)return '<tr><td colspan="7" style="color:#64748b;font-style:italic;">No components selected yet.</td></tr>';
  return rows.map(function(r){
    var tone=r.approved?'#16a34a':(r.decision==='BLOCKED'?'#dc2626':'#64748b');
    return '<tr><td style="font-weight:600;">'+r.component+'</td>'
      +'<td style="font-size:11px;color:#64748b;">'+r.vm+'</td>'
      +'<td><span style="background:'+tone+'22;color:'+tone+';padding:2px 8px;border-radius:999px;font-size:10px;font-weight:700;">'+r.decision+'</span></td>'
      +'<td style="font-size:11px;color:#334155;">'+r.snapshot+(r.simulated?'<div style="font-size:9px;color:#d97706;font-weight:700;margin-top:2px;" title="'+_R6_SNAPSHOT_SIM_NOTE.replace(/"/g,"&quot;")+'">SIMULATED - no OpenStack call</div>':'')+'</td>'
      +'<td style="font-size:10px;color:#334155;font-family:monospace;">'+(r.snapshotIds.length?r.snapshotIds.join('<br>'):'&mdash;')+'</td>'
      +'<td style="font-size:11px;color:#334155;">'+r.extraction+'</td>'
      +'<td style="font-size:11px;color:#334155;">'+r.build+(r.reason?'<div style="font-size:10px;color:#dc2626;margin-top:2px;">'+r.reason+'</div>':'')+'</td></tr>';
  }).join('');
};
var _R6_SNAPSHOT_SIM_NOTE='';
window.r6pGenRealDockerfiles=function(snapshotOnly){
  snapshotOnly=!!snapshotOnly;
  var st=document.getElementById(snapshotOnly?'r6p-snapshot-status':'r6p-build-status');
  if(!R6P.components||!R6P.components.length){if(st){st.textContent='Select a Business System in Step 1 first.';st.style.color='#dc2626';}return;}
  if(!r6pStage8ApprovedForCapture()){if(st){st.textContent='Stage 8 approval required before source capture. Approve the readiness plan first; no snapshots are created before that gate.';st.style.color='#dc2626';}return;}
  var clusterRef=(R6P.creds.opencenter.clusterRef||'rackspace-flex/flex-prod-k8s').split('/');
  var org=clusterRef[0]||'rackspace-flex',cluster=clusterRef[1]||'flex-prod-k8s';
  var comps=r6pStage9ApprovedContainerTargets().filter(function(c){return c.tgt;});
  if(!comps.length){if(st){st.textContent='No Stage 8-approved container source VMs are eligible for capture. Retained VMs, operators, databases, external services, blocked and excluded components are skipped.';st.style.color='#dc2626';}return;}
  var srcComp=comps[0];
  /* Only Stage 8-approved CONTAINERIZED/PARTIALLY_CONTAINERIZED application VMs reach
     this payload. Databases, retained/redeployed VMs, operators, external services,
     blocked and excluded components are not snapshotted for container image builds. */
  var workloads=comps.map(function(c){
    var form=r6pStage9DecisionFor(c);
    var buildable=true;
    var startCmd=(R6P.startCmdOverride&&R6P.startCmdOverride[c.name])||r6pDetectStartCommand(c);
    var siblingDeps=(R6P.components||[]).filter(function(x){return x.name!==c.name;}).map(function(x){return x.name;});
    var endpoint=r6pParseTargetEndpoint(c.tgt);
    return {component:c.name,image:'debian:stable-slim',replicas:1,
      readiness:buildable?'READY':'KEEP_ON_VM_FOR_NOW',layer:'API',sourcePath:c.path||'/opt/app',targetForm:form,
      startCommand:startCmd,healthPath:(c.path&&c.path.indexOf('/')===0)?c.path.split(',')[0]:'/health',
      dependencies:siblingDeps,targetIp:endpoint.ip,targetPort:endpoint.port,
      sourceVmId:c.vmId||c.serverId||c.instanceId||'',sourceVmName:c.vmName||c.name||'',
      cloudRegion:c.region||c.cloudRegion||(R6P.bs&&R6P.bs.region)||'iad3',volumeIds:c.volumes||c.volumeIds||[],
      persistentPath:r6pPersistentPathFor(c)};
  });
  var skipped=(R6P.components||[]).filter(function(c){return !r6pIsContainerCaptureTarget(c);}).map(function(c){return {component:c.name,targetForm:r6pStage9DecisionFor(c)};});
  if(!snapshotOnly&&!R6P.captureRun){if(st){st.textContent='Build VM Snapshots first. Container build uses the snapshot lineage produced by Stage 9A.';st.style.color='#dc2626';}return;}
  var mode=(document.querySelector('input[name="r6p-build-mode"]:checked')||{}).value||'manual';
  function r6pStage9Cred(id,key){
    var el=document.getElementById(id);
    var val=el?(el.value||''):'';
    if(!val&&R6P.creds&&R6P.creds.cloud)val=R6P.creds.cloud[key]||'';
    return val;
  }
  var cloudCreds={
    authUrl:r6pStage9Cred('r6p-c-authurl','authUrl'),
    authType:r6pStage9Cred('r6p-c-authtype','authType')||'password',
    username:r6pStage9Cred('r6p-c-username','username'),
    password:r6pStage9Cred('r6p-c-password','password'),
    credId:r6pStage9Cred('r6p-c-credid','credId'),
    secret:r6pStage9Cred('r6p-c-secret','secret'),
    proj:r6pStage9Cred('r6p-c-proj','proj')||r6pStage9Cred('r6p-c-proj','projectId'),
    domain:r6pStage9Cred('r6p-c-domain','domain')||'rackspace_cloud_domain',
    region:r6pStage9Cred('r6p-c-region','region')
  };
  var stage9Region=cloudCreds.region||'iad3';
  /* Automatic mode makes the whole R6-to-production-OpenCenter transfer fully automatic in
     one action: build+push images (client-side chain below) AND commit+push the GitOps
     overlay for real (auto_commit:true) in the same generate-bundle call. Manual mode never
     commits/pushes without a separate explicit action (Step 12's Deploy button). */
  var payload={org:org,cluster:cluster,region:stage9Region,cloud:cloudCreds,
    registry:{type:(document.getElementById('r6p-build-regtype')||{}).value||'harbor',
      url:(document.getElementById('r6p-build-regurl')||{}).value||'',
      project:(document.getElementById('r6p-build-project')||{}).value||'flex-apps',
      user:(document.getElementById('r6p-build-reguser')||{}).value||'',
      password:(document.getElementById('r6p-build-regpass')||{}).value||''},
    source_vm:{host:(srcComp&&srcComp.tgt)||'',user:'root'},
    snapshotOnly:snapshotOnly,
    auto_commit:mode==='auto'&&!snapshotOnly,import_to_gitops:!snapshotOnly,
    stage8Approved:R6P.status[8]==='done',
    businessSystem:R6P.bs||{},
    capture:{excludePaths:['/var/log','/tmp','/etc/ssh','/root/.ssh','/home/*/.ssh','/var/lib/postgresql','/var/lib/mysql','/var/lib/mongodb','/var/lib/redis','/var/backups']},
    bundle:{id:'r6p-'+Date.now(),businessSystemName:(R6P.bs&&R6P.bs.name)||'app',workloads:workloads}};
  if(st){st.textContent=snapshotOnly?'Building approved OpenStack VM/volume snapshots and recording lineage...':'Building containers from approved snapshot lineage...';st.style.color='#0369a1';}
  fetch('/api/r6/capture-sources-build',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)})
    .then(function(r){return r.json();})
    .then(function(d){
      if(!d||!d.ok){if(st){st.textContent='✗ '+((d&&d.error)||'generation failed');st.style.color='#dc2626';}return;}
      R6P._realBundle=d;
      R6P.captureRun=d.capture||R6P.captureRun||null;
      if(snapshotOnly){
        if(st){st.innerHTML='&#10003; VM snapshots ready. <code>'+((d.capture&&d.capture.approvedCount)||0)+' approved / '+((d.capture&&d.capture.reusedSnapshots)||0)+' reused / '+((d.capture&&d.capture.createdSnapshots)||0)+' created</code><br>Snapshot mode: <code>OPENSTACK_CLI</code>; handoff lineage: <code>'+((d.capture&&d.capture.snapshotIndexPath)||'~/.config/opencenter/r6/source-captures/snapshot-index.json')+'</code>';st.style.color='#15803d';}
        var snapBody=document.getElementById('r6p-capture-tbody');if(snapBody)snapBody.innerHTML=r6pBuildCaptureRows();
        return;
      }
      R6P.yaml='# Generated by /api/r6/generate-bundle\n'+d.bundle_dir;
      R6P.artifacts=R6P.artifacts||{};
      ['opencenter_import_manifest.json','k8s/','helm/','kustomize/','flux/','Dockerfile','image_build_plan.yaml',
       'app_capture_manifest.json','externalization_plan.yaml','container_readiness_report.json','container_readiness_report.md'
      ].forEach(function(k){R6P.artifacts[k]=true;});
      var skipMsg=skipped.length?('<br><span style="color:#64748b;">Skipped (not CONTAINERIZED/PARTIALLY_CONTAINERIZED): '+skipped.map(function(w){return w.component+' ('+w.targetForm+')';}).join(', ')+'</span>'):'';
      var gitopsMsg=(mode==='auto')?('<br>GitOps commit+push: <code>'+(d.gitops_commit||'skipped')+'</code>'):'';
      var capMsg=d.capture?('<br>Source capture: <code>'+d.capture.approvedCount+' approved / '+d.capture.reusedSnapshots+' reused snapshot(s) / '+d.capture.createdSnapshots+' created snapshot record(s)</code>'
        +'<br>Snapshot mode: <code>OPENSTACK_CLI</code>; lineage index: <code>'+(d.capture.snapshotIndexPath||'~/.config/opencenter/r6/source-captures/snapshot-index.json')+'</code>'):'';
      if(st){st.innerHTML='&#10003; '+d.files.length+' files written to <code>'+d.bundle_dir+'</code>'
        +(d.imported_to?'<br>&#10003; K8s manifests imported to GitOps overlay: <code>'+d.imported_to+'</code>':'<br>&#9888; GitOps repo not found - manifests not imported')
        +'<br>Pull secret: '+d.pull_secret+capMsg+skipMsg+gitopsMsg;
        st.style.color='#15803d';}
      var capBody=document.getElementById('r6p-capture-tbody');if(capBody)capBody.innerHTML=r6pBuildCaptureRows();
      var box=document.getElementById('r6p-build-cmds');
      if(!box){box=document.createElement('div');box.id='r6p-build-cmds';box.style.marginTop='10px';st.parentNode.insertBefore(box,st.nextSibling);}
      if(mode==='auto'){
        box.innerHTML='<div style="font-weight:700;font-size:12px;color:#0f172a;margin-bottom:6px;">Automatic mode - running extract, build, scan and push now:</div>'
          +'<div class="r6p-terminal" id="r6p-auto-build-out" style="display:block;max-height:320px;"></div>';
        r6pAutoRunBuildPipeline(d.extract_cmd,d.build_cmd,'r6p-auto-build-out');
      } else {
        box.innerHTML='<div style="font-weight:700;font-size:12px;color:#0f172a;margin-bottom:6px;">1. Extract app assets from the source FLEX VM</div>'
          +r6pCmd('extract9',d.extract_cmd)
          +'<div style="font-weight:700;font-size:12px;color:#0f172a;margin:10px 0 6px;">2. Build, scan, sign and push (run after extraction succeeds)</div>'
          +r6pCmd('build9',d.build_cmd);
      }
      r6pMarkDone(9);
    })
    .catch(function(e){if(st){st.textContent='✗ '+e;st.style.color='#dc2626';}});
};
window.r6pGenBundle=function(){
  if(!R6P.components.length&&!R6P.bs){alert('Select a FLEX input in Step 1 first.');return;}
  r6pGenYAML();r6pGenHelm();r6pGenFlux();
  var isC=R6P.captureMethod==='compat';
  var bsName=R6P.bs&&R6P.bs.name||'';
  var bsSlug=bsName.toLowerCase().replace(/\s+/g,'-').replace(/[^a-z0-9-]/g,'');
  var workloads=R6P.components.filter(function(c){return (c.type||c.role||'').toLowerCase()!=='database';}).map(function(c){return {name:c.name,kind:'Deployment'};});
  var extsvc=R6P.components.filter(function(c){return (c.type||c.role||'').toLowerCase()==='database';}).map(function(c){return {name:c.name,type:'ExternalDB'};});
  var warns=isC?['COMPATIBILITY_CONTAINER: not fully cloud-native']:[];
  var now=new Date().toISOString();

  /* Build opencenter_import_manifest */
  var manifest={
    sourcePlatform:'flex',
    conversionEngine:'APPS_to_Container_Refactor_Engine',
    captureMethod:isC?'FULL_SNAPSHOT_COMPATIBILITY_CONTAINER':'SMART_SNAPSHOT_CAPTURE',
    cloudNativeStatus:isC?'COMPATIBILITY_CONTAINER_ONLY':'CLOUD_NATIVE_READY',
    businessSystem:bsName,
    businessSystemId:R6P.bs&&R6P.bs.id||'',
    targetCluster:R6P.creds.opencenter.clusterRef||'rackspace-flex/flex-prod-k8s',
    namespace:bsSlug+'-prod',
    workloads:workloads,
    externalServices:extsvc,
    keptOnFlexVm:[],
    warnings:warns,
    blockers:[],
    createdAt:now
  };

  /* Build full appsContainerRefactorOutput shared state */
  var output={
    status:'ready_for_opencenter_import',
    sourceStage:'APPS_to_Container_Refactor_Engine',
    bundleName:'opencenter-ready-app-bundle',
    bundlePath:'./opencenter-ready-app-bundle/'+bsSlug,
    bundleArchivePath:'./opencenter-ready-app-bundle.tar.gz',
    businessSystemName:bsName,
    businessSystemId:R6P.bs&&R6P.bs.id||'',
    customerName:'',
    sourcePlatform:'flex',
    captureMethod:manifest.captureMethod,
    cloudNativeStatus:manifest.cloudNativeStatus,
    targetCluster:manifest.targetCluster,
    namespace:manifest.namespace,
    packageContents:{
      'opencenter_import_manifest.json':'found',
      'k8s/':R6P.yaml&&R6P.yaml.length>10?'found':'missing',
      'helm/':R6P.yaml&&R6P.yaml.length>10?'found':'missing',
      'kustomize/':'found',
      'flux/':'found',
      'Dockerfile':'found',
      'image_build_plan.yaml':'found',
      'app_capture_manifest.json':'found',
      'container_readiness_report.json':'found',
      'container_readiness_report.md':'found',
      'externalization_plan.yaml':'found',
      'compatibility_warnings.json':isC?'found':'not_required'
    },
    manifest:manifest,
    workloads:workloads,
    externalServices:extsvc,
    keptOnFlexVm:[],
    warnings:warns,
    blockers:[],
    createdAt:now
  };

  R6P.bundle=output;
  R6P._bundleValidated=false;
  R6P.artifacts=R6P.artifacts||{};
  Object.keys(output.packageContents).forEach(function(k){R6P.artifacts[k]=output.packageContents[k]==='found';});
  var body12=document.getElementById('r6p-body-12');
  if(body12){var inner12=body12.querySelector('.r6p-stage-body-inner');if(inner12)inner12.innerHTML=r6pContent(12);}

  /* Update Stage 11 UI */
  var el=document.getElementById('r6p-bundle-preview');if(el)el.textContent=JSON.stringify(manifest,null,2);
  var st=document.getElementById('r6p-bundle-status');
  if(st){st.style.background=warns.length?'#fef3c7':'#dcfce7';st.style.color=warns.length?'#d97706':'#16a34a';st.innerHTML='<strong>'+(warns.length?'PASS WITH WARNINGS':'PASS')+'</strong> | '+manifest.captureMethod;}
  var sb=document.getElementById('r6p-sum-bundle');
  if(sb){sb.textContent=warns.length?'WARNING':'Generated (PASS)';sb.style.color=warns.length?'#fbbf24':'#86efac';}

  /* Persist — legacy key kept for backwards compat */
  localStorage.setItem('appsContainerRefactorOutput',JSON.stringify(output));
  localStorage.setItem('r6OpenCenterHandoffBundle',JSON.stringify(manifest));
  r6pMarkDone(11);
  return output;
};

window.r6pValidateBundle=function(){
  if(!R6P.bundle)r6pGenBundle();
  var b=R6P.bundle;
  var blockers=[];
  if(!b.businessSystemName)blockers.push('businessSystem missing');
  if(!b.captureMethod)blockers.push('captureMethod missing');
  if(b.cloudNativeStatus==='BLOCKED')blockers.push('cloudNativeStatus is BLOCKED');
  if(!b.workloads||!b.workloads.length)blockers.push('No workloads defined');
  b.blockers=blockers;
  R6P._bundleValidated=blockers.length===0;
  /* Re-render Stage 12 to show updated validation state */
  var body=document.getElementById('r6p-body-12');
  if(body){var inner=body.querySelector('.r6p-stage-body-inner');if(inner)inner.innerHTML=r6pContent(12);}
  var sb=document.getElementById('r6p-sum-bundle');
  if(sb){sb.textContent=blockers.length?'BLOCKED':b.warnings.length?'Ready (warnings)':'Ready for Import';sb.style.color=blockers.length?'#f87171':b.warnings.length?'#fbbf24':'#86efac';}
  if(!R6P._bundleValidated){alert('Validation failed:\n\n'+blockers.join('\n'));}
  return R6P._bundleValidated;
};

window.r6pSendToOC=function(){
  if(!R6P.bundle)r6pGenBundle();
  if(!R6P._bundleValidated&&!r6pValidateBundle()){return;}
  var out=R6P.bundle;
  out.status='ready_for_opencenter_import';
  localStorage.setItem('appsContainerRefactorOutput',JSON.stringify(out));
  localStorage.setItem('r6OpenCenterHandoffBundle',JSON.stringify(out.manifest||out));
  /* Notify OpenCenter stage */
  setTimeout(function(){if(typeof openCenterImportFromR6==='function')openCenterImportFromR6();},300);
  /* Navigate to OpenCenter */
  var s=document.querySelector('[data-sub="s2opencenter"]');
  if(s)setTimeout(function(){s.click();},600);
  /* Show success in Stage 12 */
  var sb=document.getElementById('r6p-sum-bundle');if(sb){sb.textContent='Sent to OpenCenter';sb.style.color='#86efac';}
  var st=document.getElementById('r6p-s12-status');if(st){st.textContent='Sent to OpenCenter Import Stage';st.style.color='#16a34a';}
  /* Flash success message */
  var banner=document.createElement('div');
  banner.style.cssText='position:fixed;top:70px;right:20px;z-index:9999;background:#16a34a;color:#fff;padding:14px 20px;border-radius:8px;font-size:13px;font-weight:700;max-width:380px;box-shadow:0 4px 20px rgba(0,0,0,.2);';
  banner.textContent='Apps Container Refactor output sent to OpenCenter Import stage. Review the package, validate the bundle, then import through OpenCenter.';
  document.body.appendChild(banner);
  setTimeout(function(){banner.style.opacity='0';banner.style.transition='opacity .5s';setTimeout(function(){banner.parentNode&&banner.parentNode.removeChild(banner);},500);},5000);
  r6pMarkDone(12);
};

/* Real, fully-automatic R6-to-production-OpenCenter transfer: re-runs the same real
   generate-bundle backend used by Step 9, but with auto_commit:true so it actually runs
   git add/commit/push against the production GitOps repo (org/cluster resolved from the
   real Production OpenCenter panel via r6pGitLoad, not a placeholder). Safe to call even
   if Step 9 was run in Manual mode - it regenerates the bundle from current state first. */
window.r6pAutoDeployToOpenCenter=function(){
  var st=document.getElementById('r6p-auto-deploy-status');
  if(!R6P.components||!R6P.components.length){if(st){st.textContent='Select a Business System in Step 1 first.';st.style.color='#dc2626';}return;}
  var clusterRef=(R6P.creds.opencenter.clusterRef||'rackspace-flex/flex-prod-k8s').split('/');
  var org=clusterRef[0]||'rackspace-flex',cluster=clusterRef[1]||'flex-prod-k8s';
  var comps=R6P.components.filter(function(c){return c.tgt;});
  var workloads=comps.map(function(c){
    var form=(R6P.targetForms&&R6P.targetForms[c.name])||r6pDecideTargetForm(c).form;
    var buildable=(form==='CONTAINERIZED'||form==='PARTIALLY_CONTAINERIZED');
    return {component:c.name,image:'debian:stable-slim',replicas:1,
      readiness:buildable?'READY':'KEEP_ON_VM_FOR_NOW',layer:'API',sourcePath:c.path||'/opt/app',targetForm:form,
      persistentPath:r6pPersistentPathFor(c)};
  });
  var payload={org:org,cluster:cluster,region:'iad3',
    registry:{type:(document.getElementById('r6p-build-regtype')||{}).value||'harbor',
      url:(document.getElementById('r6p-build-regurl')||{}).value||'',
      project:(document.getElementById('r6p-build-project')||{}).value||'flex-apps',
      user:(document.getElementById('r6p-build-reguser')||{}).value||'',
      password:(document.getElementById('r6p-build-regpass')||{}).value||''},
    source_vm:{host:(comps[0]&&comps[0].tgt)||'',user:'root'},
    auto_commit:true,import_to_gitops:true,
    bundle:{id:'r6p-deploy-'+Date.now(),businessSystemName:(R6P.bs&&R6P.bs.name)||'app',workloads:workloads}};
  if(st){st.textContent='Deploying to production GitOps (org='+org+', cluster='+cluster+')...';st.style.color='#0369a1';}
  fetch('/api/r6/generate-bundle',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)})
    .then(function(r){return r.json();})
    .then(function(d){
      if(!d||!d.ok){if(st){st.textContent='✗ '+((d&&d.error)||'deploy failed');st.style.color='#dc2626';}return;}
      if(st){st.innerHTML='&#10003; Imported to <code>'+(d.imported_to||'(not imported - no gitops dir for org '+org+')')+'</code>'
        +'<br>Commit+push result: <code>'+(d.gitops_commit||'skipped')+'</code>';
        st.style.color=(d.gitops_commit&&d.gitops_commit.indexOf('push -> 0')>=0)?'#15803d':'#d97706';}
      r6pMarkDone(12);
    })
    .catch(function(e){if(st){st.textContent='✗ '+e;st.style.color='#dc2626';}});
};
window.r6pMarkUatSignoff=function(){
  R6P.uatSignedOff=new Date().toISOString();
  var el=document.getElementById('r6p-uat-signoff-status');
  if(el){el.textContent='Signed off '+R6P.uatSignedOff;el.style.color='#16a34a';}
};

window.r6pPreviewArtifact=function(f){
  var content='';
  if(f==='opencenter_import_manifest.json')content=JSON.stringify((R6P.bundle&&R6P.bundle.manifest)||{},null,2);
  else if(f==='source-lineage.json'||f==='source-capture-manifest.json'){
    if(!R6P.captureRun)content='-- Run "Capture Sources & Build Containers" in Stage 9 first --';
    else content=JSON.stringify(R6P.captureRun,null,2);
  }
  else if(f.match(/^(k8s\/|Dockerfile)/))content=R6P.yaml||'-- Generate YAML in Step 10 first --';
  else if(f.match(/helm\//))content=r6pHelmPreview();
  else if(f.match(/flux\//))content=r6pFluxPreview();
  else content='-- Preview not available. Generate artifacts in Steps 9-11 first. --';
  var w=window.open('','_blank','width=700,height=600');
  if(w){w.document.write('<pre style="font-family:monospace;font-size:12px;padding:20px;background:#0f172a;color:#2dd4bf;margin:0;white-space:pre-wrap;">'+content.replace(/</g,'&lt;')+'</pre>');w.document.close();}
};

function r6pHelmPreview(){var n=((R6P.bs&&R6P.bs.name)||'app').toLowerCase().replace(/\s+/g,'-');return '# Chart.yaml\napiVersion: v2\nname: '+n+'\nversion: 1.0.0\n\n# values.yaml\nreplicaCount: 2\nimage:\n  repository: registry.example.com/'+n+'\n  tag: v1.0.0\n';}
function r6pFluxPreview(){var n=((R6P.bs&&R6P.bs.name)||'app').toLowerCase().replace(/\s+/g,'-');return 'apiVersion: kustomize.toolkit.fluxcd.io/v1\nkind: Kustomization\nmetadata:\n  name: '+n+'\n  namespace: flux-system\nspec:\n  interval: 5m\n  path: "./applications/overlays/'+n+'"\n  prune: true\n  sourceRef:\n    kind: GitRepository\n    name: opencenter-gitops\n';}

window.r6pDownloadEvidence=function(){
  var data=R6P.bundle||{};
  var a=document.createElement('a');
  a.href='data:application/json;charset=utf-8,'+encodeURIComponent(JSON.stringify(data,null,2));
  a.download='opencenter_import_manifest.json';a.click();
};
window.r6pDownloadBundle=window.r6pDownloadEvidence;

/* ── Stage 0: Preflight ─────────────────────────────────── */
window.r6pStage0=function(){
  function toolRow(t){
    var s=R6P.preflight[t.name]||'unchecked';
    var sbg={ok:'#dcfce7',missing:'#fee2e2',checking:'#fef3c7',unchecked:'#f1f5f9'}[s]||'#f1f5f9';
    var sfg={ok:'#16a34a',missing:'#dc2626',checking:'#d97706',unchecked:'#94a3b8'}[s]||'#94a3b8';
    var stxt={ok:'Installed',missing:t.manual?'Manual Setup Required':'Missing',checking:'Checking...',unchecked:'Not Checked'}[s]||'Not Checked';
    var ver=R6P.preflight[t.name+'_ver']||'—';
    var btn='';
    if(s==='missing'&&!t.manual)btn='<button onclick="r6pShowInstallConfirm([\''+t.name+'\'])" style="background:#0369a1;color:#fff;border:none;border-radius:4px;padding:3px 10px;font-size:10px;font-weight:700;cursor:pointer;">Install</button>';
    else if(s==='missing'&&t.manual)btn='<button onclick="r6pShowOcSetup()" style="background:#7c3aed;color:#fff;border:none;border-radius:4px;padding:3px 10px;font-size:10px;font-weight:700;cursor:pointer;">Configure Path</button>';
    else if(s==='ok')btn='<span style="color:#16a34a;font-size:11px;font-weight:700;">OK</span>';
    return '<tr id="r6p-tr-'+t.name+'">'
      +'<td style="font-weight:700;font-size:12px;">'+t.name+'</td>'
      +'<td><span style="background:'+(t.req?'#fee2e2':'#fef3c7')+';color:'+(t.req?'#dc2626':'#d97706')+';padding:2px 8px;border-radius:999px;font-size:10px;font-weight:700;">'+(t.req?'Required':'Recommended')+'</span></td>'
      +'<td><span id="r6p-st-'+t.name+'" style="background:'+sbg+';color:'+sfg+';padding:2px 8px;border-radius:999px;font-size:10px;font-weight:700;">'+stxt+'</span></td>'
      +'<td id="r6p-ver-'+t.name+'" style="font-size:11px;color:#475569;font-family:monospace;">'+ver+'</td>'
      +'<td id="r6p-btn-'+t.name+'">'+btn+'</td>'
      +'<td style="font-size:11px;color:#64748b;">'+t.note+'</td></tr>';
  }

  var csStatus=R6P.creds.cloud.status,ocStatus=R6P.creds.opencenter.status,gsStatus=R6P.creds.gitops.status;
  function statusBadge(s){var m={not_configured:['#f1f5f9','#94a3b8','Not Configured'],configured:['#fef3c7','#d97706','Configured'],connected:['#dcfce7','#16a34a','Connected'],failed:['#fee2e2','#dc2626','Failed'],validating:['#fef3c7','#d97706','Validating'],manual_setup:['#faf5ff','#7c3aed','Manual Setup Required']}[s]||['#f1f5f9','#94a3b8','Unknown'];return '<span style="background:'+m[0]+';color:'+m[1]+';padding:2px 10px;border-radius:999px;font-size:10px;font-weight:700;">'+m[2]+'</span>';}

  return '<div style="display:flex;flex-direction:column;gap:20px;">'

    /* ─── SECTION A: CLI Tools ─── */
    +'<div style="border:1.5px solid #e2e8f0;border-radius:10px;overflow:hidden;">'
    +'<div style="background:#0f172a;color:#fff;padding:12px 18px;display:flex;justify-content:space-between;align-items:center;">'
    +'<div style="font-weight:800;font-size:14px;">A — CLI Tools</div>'
    +'<div style="display:flex;gap:6px;flex-wrap:wrap;">'
    +'<button class="r6p-btn primary" onclick="r6pRunPreflight()" style="padding:5px 12px;font-size:11px;">Run Preflight</button>'
    +'<button class="r6p-btn success" onclick="r6pShowInstallConfirm(\'missing\')" style="padding:5px 12px;font-size:11px;">Install Missing</button>'
    +'<button class="r6p-btn danger"  onclick="r6pShowInstallConfirm(\'required\')" style="padding:5px 12px;font-size:11px;">Install Required Only</button>'
    +'<button class="r6p-btn amber"   onclick="r6pShowInstallConfirm(\'recommended\')" style="padding:5px 12px;font-size:11px;">Install Recommended</button>'
    +'</div></div>'
    +'<div style="padding:14px;overflow-x:auto;">'
    +'<table class="r6p-table"><thead><tr><th>Tool</th><th>Required?</th><th>Status</th><th>Version</th><th>Install</th><th>Notes</th></tr></thead>'
    +'<tbody id="r6p-tool-tbody">'+R6P_TOOLS.map(toolRow).join('')+'</tbody></table>'
    +'</div>'
    +'<div id="r6p-preflight-out" class="r6p-terminal" style="display:none;margin:0 14px 14px;max-height:140px;"></div>'
    +'</div>'

    /* ─── SECTION B: Credentials & Access ─── */
    +'<div style="border:1.5px solid #e2e8f0;border-radius:10px;overflow:hidden;">'
    +'<div style="background:#0f172a;color:#fff;padding:12px 18px;font-weight:800;font-size:14px;">B — Credentials & Access</div>'
    +'<div style="padding:14px;display:flex;flex-direction:column;gap:12px;">'

    /* Cloud/OpenStack */
    +'<div style="border:1px solid #e2e8f0;border-radius:8px;overflow:hidden;">'
    +'<div onclick="r6pToggleCred(\'cloud\')" style="display:flex;justify-content:space-between;align-items:center;padding:10px 14px;background:#f8fafc;cursor:pointer;">'
    +'<div><div style="font-weight:700;font-size:13px;">1. FLEX / OpenStack Cloud Credentials</div>'
    +'<div style="font-size:11px;color:#64748b;">Application Credential recommended for automation</div></div>'
    +'<span id="r6p-cloud-badge">'+statusBadge(csStatus)+'</span></div>'
    +'<div id="r6p-cred-cloud" style="display:block;padding:16px;">'
    +'<div style="font-size:13px;font-weight:800;color:#0f172a;margin-bottom:12px;">V3 FLEX Cloud Credentials <span style="font-size:11px;font-weight:400;color:#64748b;">(FLEX v3 auth)</span></div>'
    +'<div style="margin-bottom:10px;"><label style="font-size:12px;font-weight:600;color:#334155;display:block;margin-bottom:4px;">Auth URL</label><input id="r6p-c-authurl" placeholder="https://keystone.api.iad3.rackspacecloud.com/v3/" style="width:100%;padding:8px 10px;border:1px solid #e2e8f0;border-radius:5px;font-size:13px;box-sizing:border-box;" oninput="r6pSaveCredCache()" onchange="r6pSaveCred(\'cloud\',\'authUrl\',this.value)"></div>'
    +'<div style="margin-bottom:10px;"><label style="font-size:12px;font-weight:600;color:#334155;display:block;margin-bottom:4px;">Type of Auth</label>'
    +'<select id="r6p-c-authtype" onchange="r6pAuthTypeChange(this.value);r6pSaveCredCache();" style="width:100%;padding:8px 10px;border:1px solid #e2e8f0;border-radius:5px;font-size:13px;">'
    +'<option value="password">Username / Password</option>'
    +'<option value="appcred">Application Credential</option>'
    +'</select></div>'
    /* Username/Password fields */
    +'<div id="r6p-c-pw-fields">'
    +'<div style="margin-bottom:10px;"><label style="font-size:12px;font-weight:600;color:#334155;display:block;margin-bottom:4px;">Username</label><input id="r6p-c-username" style="width:100%;padding:8px 10px;border:1px solid #e2e8f0;border-radius:5px;font-size:13px;box-sizing:border-box;" oninput="r6pSaveCredCache()" onchange="r6pSaveCred(\'cloud\',\'username\',this.value)"></div>'
    +'<div style="margin-bottom:10px;"><label style="font-size:12px;font-weight:600;color:#334155;display:block;margin-bottom:4px;">Password</label><input id="r6p-c-password" type="password" style="width:100%;padding:8px 10px;border:1px solid #e2e8f0;border-radius:5px;font-size:13px;box-sizing:border-box;" oninput="r6pSaveCredCache()"></div>'
    +'</div>'
    /* App Credential fields */
    +'<div id="r6p-c-appcred-fields" style="display:none;">'
    +'<div style="margin-bottom:10px;"><label style="font-size:12px;font-weight:600;color:#334155;display:block;margin-bottom:4px;">OS_APPLICATION_CREDENTIAL_ID</label><input id="r6p-c-credid" placeholder="OS_APPLICATION_CREDENTIAL_ID" style="width:100%;padding:8px 10px;border:1px solid #e2e8f0;border-radius:5px;font-size:13px;box-sizing:border-box;" oninput="r6pSaveCredCache()" onchange="r6pSaveCred(\'cloud\',\'credId\',this.value)"></div>'
    +'<div style="margin-bottom:8px;"><label style="font-size:12px;font-weight:600;color:#334155;display:block;margin-bottom:4px;">OS_APPLICATION_CREDENTIAL_SECRET</label><input id="r6p-c-secret" type="password" placeholder="OS_APPLICATION_CREDENTIAL_SECRET" style="width:100%;padding:8px 10px;border:1px solid #e2e8f0;border-radius:5px;font-size:13px;box-sizing:border-box;"></div>'
    +'<div style="background:#f0f9ff;border:1px solid #bae6fd;border-radius:5px;padding:8px 10px;font-size:11px;color:#0369a1;margin-bottom:10px;">Uses OS_AUTH_TYPE=v3applicationcredential. Project and domain can remain for compatibility, but Keystone scopes the application credential.</div>'
    +'</div>'
    +'<div style="margin-bottom:10px;"><label style="font-size:12px;font-weight:600;color:#334155;display:block;margin-bottom:4px;">Project ID</label><input id="r6p-c-proj" style="width:100%;padding:8px 10px;border:1px solid #e2e8f0;border-radius:5px;font-size:13px;box-sizing:border-box;" oninput="r6pSaveCredCache()" onchange="r6pSaveCred(\'cloud\',\'projectId\',this.value)"></div>'
    +'<div style="margin-bottom:10px;"><label style="font-size:12px;font-weight:600;color:#334155;display:block;margin-bottom:4px;">Domain</label><input id="r6p-c-domain" value="rackspace_cloud_domain" style="width:100%;padding:8px 10px;border:1px solid #e2e8f0;border-radius:5px;font-size:13px;box-sizing:border-box;" oninput="r6pSaveCredCache()"></div>'
    +'<div style="margin-bottom:14px;"><label style="font-size:12px;font-weight:600;color:#334155;display:block;margin-bottom:4px;">Target Region <span style="font-size:10px;font-weight:400;color:#94a3b8;">(FLEX Glance upload destination)</span></label>'
    +'<select id="r6p-c-region" onchange="r6pSaveCred(\'cloud\',\'region\',this.value);r6pSaveCredCache();" style="width:100%;padding:8px 10px;border:1px solid #e2e8f0;border-radius:5px;font-size:13px;">'
    +'<option value="">-- Select Region --</option>'
    +'<option value="IAD">us IAD3 — Northern Virginia Legacy (US)</option>'
    +'<option value="IAD3">us IAD3 — Northern Virginia (US)</option>'
    +'<option value="DFW">us DFW1 — Dallas/Fort Worth Legacy (US)</option>'
    +'<option value="DFW3">us DFW3 — Dallas/Fort Worth Legacy (US)</option>'
    +'<option value="ORD">us ORD1 — Chicago Legacy (US)</option>'
    +'<option value="SYD">ap SYD2 — Sydney (AU)</option>'
    +'<option value="LON">eu LON3 — London (UK)</option>'
    +'<option value="HKG">ap HKG1 — Hong Kong</option>'
    +'</select></div>'
    +'<div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-bottom:8px;">'
    +'<label style="display:flex;align-items:center;gap:6px;cursor:pointer;border:1px solid #e2e8f0;border-radius:5px;padding:6px 12px;font-size:12px;background:#f8fafc;">'
    +'<input type="file" accept=".sh,.rc,.env,.txt" style="display:none;" onchange="r6pImportOpenRC(event);var n=this.files[0];document.getElementById(\'r6p-c-fname\').textContent=n?n.name:\'No file chosen\'">'
    +'<span>Choose File</span></label>'
    +'<span id="r6p-c-fname" style="font-size:11px;color:#64748b;">No file chosen</span>'
    +'<button onclick="this.previousSibling.previousSibling.querySelector(\'input\').click()" style="background:#dc2626;color:#fff;border:none;border-radius:5px;padding:7px 16px;font-size:12px;font-weight:700;cursor:pointer;">Import OpenRC File</button>'
    +'<button onclick="r6pTestCloud()" style="background:#dc2626;color:#fff;border:none;border-radius:5px;padding:7px 16px;font-size:12px;font-weight:700;cursor:pointer;">Test Cloud Login</button>'
    +'</div>'
    +'<div id="r6p-cloud-result" style="font-size:12px;min-height:18px;margin-top:4px;"></div>'
    +'<div style="font-size:10px;color:#94a3b8;margin-top:6px;">Cached in this browser (localStorage) so you do not have to re-enter credentials. Never committed to GitOps repo or evidence bundles.</div>'
    +'</div></div>'


    /* 2. GitOps credentials (synced with OpenCenter Production panel state - ocqp, never Quickstart/ocqs) */
    +'<div style="border:1px solid #e2e8f0;border-radius:8px;padding:14px 16px;margin:12px 16px 16px;">'
    +'<div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px;">'
    +'<div><div style="font-weight:700;font-size:13px;">2. GitOps Credentials</div>'
    +'<div style="font-size:11px;color:#64748b;">Repo + auth used to push refactored app manifests into the OpenCenter pipeline</div></div>'
    +'<span id="r6p-git-badge" style="font-size:10px;font-weight:800;color:#94a3b8;">Not Configured</span></div>'
    +'<div style="display:grid;grid-template-columns:2fr 1fr 1fr;gap:10px;">'
    +'<div><label style="font-size:11px;font-weight:700;color:#334155;display:block;">GitOps Repository URL</label>'
    +'<input id="r6p-git-repo" style="width:100%;padding:6px;border:1px solid #cbd5e1;border-radius:5px;font-size:12px;" placeholder="https://github.com/USER/repo.git" oninput="r6pGitSave()"></div>'
    +'<div><label style="font-size:11px;font-weight:700;color:#334155;display:block;">Branch</label>'
    +'<input id="r6p-git-branch" value="main" style="width:100%;padding:6px;border:1px solid #cbd5e1;border-radius:5px;font-size:12px;" oninput="r6pGitSave()"></div>'
    +'<div><label style="font-size:11px;font-weight:700;color:#334155;display:block;">Auth Method</label>'
    +'<select id="r6p-git-auth" onchange="r6pGitAuthToggle();r6pGitSave();" style="width:100%;padding:6px;border:1px solid #cbd5e1;border-radius:5px;font-size:12px;">'
    +'<option value="ssh" selected>SSH key</option><option value="token">HTTPS token</option></select></div>'
    +'</div>'
    +'<div id="r6p-git-ssh-row" style="margin-top:8px;"><label style="font-size:11px;font-weight:700;color:#334155;display:block;">SSH Key Path</label>'
    +'<input id="r6p-git-sshkey" value="~/.ssh/id_rsa" style="width:100%;padding:6px;border:1px solid #cbd5e1;border-radius:5px;font-size:12px;" oninput="r6pGitSave()"></div>'
    +'<div style="margin-top:8px;"><label style="font-size:11px;font-weight:700;color:#334155;display:block;">Local GitOps Directory <span style="font-weight:400;color:#94a3b8;">(used by GitOps Preflight below)</span></label>'
    +'<input id="r6p-git-localdir" placeholder="/home/dzoan/.config/opencenter/clusters/gitops/my-org" style="width:100%;padding:6px;border:1px solid #cbd5e1;border-radius:5px;font-size:12px;" oninput="r6pGitSave()"></div>'
    +'<div id="r6p-git-token-row" style="margin-top:8px;display:none;"><label style="font-size:11px;font-weight:700;color:#334155;display:block;">Git Token (stored session-only)</label>'
    +'<input id="r6p-git-token" type="password" style="width:100%;padding:6px;border:1px solid #cbd5e1;border-radius:5px;font-size:12px;" placeholder="ghp_..." oninput="r6pGitSave()"></div>'
    +'<div style="display:flex;gap:8px;margin-top:10px;align-items:center;">'
    +'<button onclick="r6pGitSave()" style="background:#0f172a;color:#fff;border:none;border-radius:5px;padding:7px 16px;font-size:12px;font-weight:700;cursor:pointer;">Save GitOps Credentials</button>'
    +'<span id="r6p-git-status" style="font-size:12px;color:#64748b;"></span></div>'
    +'</div>'
    +'</div></div>'/* end section B */

    /* ─── SECTION C: GitOps Preflight ─── */
    +'<div style="border:1.5px solid #e2e8f0;border-radius:10px;overflow:hidden;">'
    +'<div style="background:#0f172a;color:#fff;padding:12px 18px;display:flex;justify-content:space-between;align-items:center;">'
    +'<div style="font-weight:800;font-size:14px;">C — GitOps Preflight</div>'
    +'<div style="display:flex;gap:6px;">'
    +'<button class="r6p-btn primary" onclick="r6pRunGitopsPreflight()" style="padding:5px 12px;font-size:11px;">Run GitOps Preflight</button>'
    +'<button class="r6p-btn secondary" onclick="r6pRunPreflight()" style="padding:5px 12px;font-size:11px;">Re-run All Checks</button>'
    +'<button class="r6p-btn secondary" onclick="r6pTestKubectlLive()" style="padding:5px 12px;font-size:11px;background:#0369a1;color:#fff;">&#9654; Test kubectl Live</button>'
    +'</div></div>'
    +'<div style="padding:14px;overflow-x:auto;">'
    +'<table class="r6p-table"><thead><tr><th>Check</th><th>Status</th><th>Result</th></tr></thead><tbody id="r6p-gitops-checks">'
    +[['GITOPS_DIR set','r6p-gc-gitdir'],['Is a Git repo','r6p-gc-isrepo'],['Has remote','r6p-gc-remote'],['applications/workloads exists','r6p-gc-workloads'],['git user.name configured','r6p-gc-gituser'],['git user.email configured','r6p-gc-gitemail'],['Flux installed','r6p-gc-flux'],['kubectl access','r6p-gc-kubectl']].map(function(c){return '<tr><td style="font-weight:600;font-size:12px;">'+c[0]+'</td><td><span id="'+c[1]+'-st" style="background:#f1f5f9;color:#94a3b8;padding:2px 8px;border-radius:999px;font-size:10px;font-weight:700;">Not Checked</span></td><td id="'+c[1]+'-val" style="font-size:11px;color:#64748b;">—</td></tr>';}).join('')
    +'</tbody></table>'
    +'</div>'
    +'<div id="r6p-gc-out" class="r6p-terminal" style="display:none;margin:0 14px 14px;max-height:140px;"></div>'
    +'</div>'/* end section C */

    /* ─── CONTINUE BUTTON ─── */
    +'<div style="display:flex;justify-content:flex-end;gap:10px;padding-top:4px;">'
    +'<button class="r6p-btn secondary" onclick="r6pRunPreflight()" style="padding:8px 18px;">Re-run Preflight</button>'
    +'<button id="r6p-s0-continue" class="r6p-btn success" onclick="r6pS0Continue()" style="padding:8px 22px;opacity:0.5;cursor:not-allowed;">Continue to Refactor</button>'
    +'</div>'

    /* ─── INSTALL CONFIRMATION MODAL ─── */
    +'<div id="r6p-install-modal" style="display:none;position:fixed;inset:0;background:rgba(0,0,0,.5);z-index:9999;display:none;align-items:center;justify-content:center;">'
    +'<div style="background:#fff;border-radius:12px;padding:24px;max-width:560px;width:90%;box-shadow:0 20px 60px rgba(0,0,0,.3);">'
    +'<h3 style="margin:0 0 8px;font-size:16px;color:#0f172a;">Install Missing CLI Tools</h3>'
    +'<p style="font-size:13px;color:#475569;margin:0 0 12px;">The following tools will be installed. This may require <code>sudo</code> access.</p>'
    +'<div id="r6p-modal-toollist" style="background:#f8fafc;border:1px solid #e2e8f0;border-radius:6px;padding:10px;font-family:monospace;font-size:12px;color:#0f172a;margin-bottom:12px;white-space:pre-wrap;"></div>'
    +'<div id="r6p-modal-oserr" style="display:none;background:#fef3c7;border:1px solid #f59e0b;border-radius:6px;padding:10px;font-size:12px;color:#92400e;margin-bottom:12px;"></div>'
    +'<div style="font-size:11px;color:#94a3b8;margin-bottom:10px;">Detected OS: <span id="r6p-modal-os">Ubuntu/Debian — auto-install supported</span></div>'
    +'<div style="margin-bottom:14px;">'
    +'<label style="font-size:12px;font-weight:700;color:#0f172a;display:block;margin-bottom:5px;">sudo Password</label>'
    +'<input type="password" id="r6p-sudo-pass" placeholder="Enter your sudo password" autocomplete="current-password" style="width:100%;padding:8px 10px;border:1.5px solid #e2e8f0;border-radius:6px;font-size:13px;box-sizing:border-box;" onkeydown="if(event.key===\'Enter\')r6pDoInstall()">'
    +'<div style="font-size:10px;color:#94a3b8;margin-top:4px;">Used once to authenticate sudo. Not stored. Cleared after install starts.</div>'
    +'</div>'
    +'<div style="display:flex;gap:8px;justify-content:flex-end;">'
    +'<button onclick="r6pCloseInstallModal()" style="background:#f1f5f9;color:#334155;border:1px solid #e2e8f0;border-radius:6px;padding:8px 16px;font-size:12px;font-weight:700;cursor:pointer;">Cancel</button>'
    +'<button id="r6p-modal-confirm" onclick="r6pDoInstall()" style="background:#0369a1;color:#fff;border:none;border-radius:6px;padding:8px 18px;font-size:12px;font-weight:800;cursor:pointer;">Install Tools</button>'
    +'</div></div></div>'

    +'</div>';/* end outer flex */
};

/* ── Preflight helpers ── */
window.r6pRunPreflight=function(done){
  var out=document.getElementById('r6p-preflight-out');if(out)out.style.display='block';
  R6P_TOOLS.forEach(function(t){r6pSetToolStatus(t.name,'checking','—');});
  var cmd='for t in git curl jq kubectl flux openstack helm yq kustomize opencenter; do '
    +'if command -v "$t" >/dev/null 2>&1; then v=$(timeout 2 "$t" --version 2>/dev/null | head -1 | tr -d "\\n"); [ -z "$v" ] && v="installed"; echo "OK:$t:$v"; '
    +'else echo "MISSING:$t"; fi; done';
  var url='/api/stream/run-cmd?cmd='+encodeURIComponent(cmd);
  var es=new EventSource(url);
  var buf='',_done=false;
  var finish=function(reason){
    if(_done)return;
    _done=true;
    try{es.close();}catch(e){}
    R6P_TOOLS.forEach(function(t){
      if(R6P.preflight[t.name]==='checking'||!R6P.preflight[t.name]){
        R6P.preflight[t.name]='missing';
        R6P.preflight[t.name+'_ver']=reason||'preflight timed out';
        r6pSetToolStatus(t.name,'missing',reason||'preflight timed out');
      }
    });
    if(out&&reason){out.textContent+=(buf?'\n':'')+'[WARN] '+reason+'\n';}
    r6pCheckContinue();
    if(typeof done==='function')done({ok:R6P_TOOLS.every(function(t){return !t.req||R6P.preflight[t.name]==='ok';}),reason:reason||''});
  };
  var watchdog=setTimeout(function(){finish('preflight timed out - marked unresolved tools as missing')},8000);
  es.onmessage=function(e){
    if(e.data==='[DONE]'||e.data.indexOf('[EXIT')===0){clearTimeout(watchdog);finish(/\[EXIT 0\]/.test(e.data)?'':'preflight command failed');return;}
    buf+=e.data+'\n';
    if(out){out.textContent=buf;out.scrollTop=out.scrollHeight;}
    var m=e.data.match(/^(OK|MISSING):([^:]+):?(.*)?$/);
    if(m){
      var name=m[2].trim(),status=m[1]==='OK'?'ok':'missing',ver=m[3]?m[3].trim():'—';
      R6P.preflight[name]=status;R6P.preflight[name+'_ver']=ver;
      r6pSetToolStatus(name,status,ver);
      if(name==='opencenter'&&status==='missing'){var w=document.getElementById('r6p-oc-missing-warn');if(w)w.style.display='block';}
    }
  };
  es.onerror=function(){clearTimeout(watchdog);finish('preflight stream closed before completion - marked unresolved tools as missing');};
};

window.r6pSetToolStatus=function(name,status,ver){
  var st=document.getElementById('r6p-st-'+name);
  var vEl=document.getElementById('r6p-ver-'+name);
  var bEl=document.getElementById('r6p-btn-'+name);
  var tool=R6P_TOOLS.find(function(t){return t.name===name;});
  if(!tool||!st)return;
  var map={ok:['#dcfce7','#16a34a','Installed'],missing:['#fee2e2','#dc2626',tool.manual?'Manual Setup Required':'Missing'],checking:['#fef3c7','#d97706','Checking...'],unchecked:['#f1f5f9','#94a3b8','Not Checked']};
  var m=map[status]||map.unchecked;
  st.style.background=m[0];st.style.color=m[1];st.textContent=m[2];
  if(vEl&&ver)vEl.textContent=ver;
  if(bEl){
    if(status==='missing'&&!tool.manual)bEl.innerHTML='<button onclick="r6pShowInstallConfirm([\''+name+'\'])" style="background:#0369a1;color:#fff;border:none;border-radius:4px;padding:3px 10px;font-size:10px;font-weight:700;cursor:pointer;">Install</button>';
    else if(status==='missing'&&tool.manual)bEl.innerHTML='<button onclick="r6pShowOcSetup()" style="background:#7c3aed;color:#fff;border:none;border-radius:4px;padding:3px 10px;font-size:10px;font-weight:700;cursor:pointer;">Configure Path</button>';
    else if(status==='ok')bEl.innerHTML='<span style="color:#16a34a;font-size:11px;font-weight:700;">OK</span>';
    else if(status==='checking')bEl.innerHTML='<span style="color:#d97706;font-size:11px;">...</span>';
  }
};

window.r6pCheckContinue=function(){
  var requiredMissing=R6P_TOOLS.filter(function(t){return t.req&&R6P.preflight[t.name]==='missing';});
  var btn=document.getElementById('r6p-s0-continue');
  if(!btn)return;
  if(requiredMissing.length===0){
    R6P.continueBlocked=false;
    btn.style.opacity='1';btn.style.cursor='pointer';
    btn.title='All required tools installed';
  } else {
    R6P.continueBlocked=true;
    btn.style.opacity='0.5';btn.style.cursor='not-allowed';
    btn.title='Missing required: '+requiredMissing.map(function(t){return t.name;}).join(', ');
  }
};

window.r6pS0Continue=function(){
  if(R6P.continueBlocked){alert('Install all required tools first.\n\nMissing: '+R6P_TOOLS.filter(function(t){return t.req&&R6P.preflight[t.name]==='missing';}).map(function(t){return t.name;}).join(', '));return;}
  r6pGoTo(1);
};

/* Install modal */
var _r6pInstallToolList=[];
window.r6pShowInstallConfirm=function(mode){
  var tools=[];
  if(Array.isArray(mode)){tools=mode;}
  else if(mode==='missing')tools=R6P_TOOLS.filter(function(t){return !t.manual&&R6P.preflight[t.name]==='missing';}).map(function(t){return t.name;});
  else if(mode==='required')tools=R6P_TOOLS.filter(function(t){return t.req&&!t.manual&&R6P.preflight[t.name]==='missing';}).map(function(t){return t.name;});
  else if(mode==='recommended')tools=R6P_TOOLS.filter(function(t){return !t.req&&!t.manual&&R6P.preflight[t.name]==='missing';}).map(function(t){return t.name;});
  if(!tools.length){alert('No installable tools to install. Run Preflight first.');return;}
  _r6pInstallToolList=tools;
  var modal=document.getElementById('r6p-install-modal');
  var tlist=document.getElementById('r6p-modal-toollist');
  var oerr=document.getElementById('r6p-modal-oserr');
  var confirmBtn=document.getElementById('r6p-modal-confirm');
  if(tlist)tlist.textContent=tools.join(' ');
  if(oerr)oerr.style.display='none';
  if(confirmBtn)confirmBtn.disabled=false;
  if(modal){modal.style.display='flex';setTimeout(function(){var p=document.getElementById('r6p-sudo-pass');if(p)p.focus();},100);}
};
window.r6pCloseInstallModal=function(){var m=document.getElementById('r6p-install-modal');if(m)m.style.display='none';};
window.r6pShowOcSetup=function(){
  alert('OpenCenter CLI Manual Setup\n\n1. Clone the openCenter-cli repo\n2. Run: mise trust && mise install && mise run build\n3. Run: sudo cp ./bin/opencenter /usr/local/bin/opencenter\n4. Run: opencenter version\n\nDo not auto-install OpenCenter CLI without an official installer URL configured in OPENCENTER_INSTALL_URL.');
};

window.r6pDoInstall=function(){
  /* Read sudo password from modal — used once, then cleared */
  var passEl=document.getElementById('r6p-sudo-pass');
  var pass=passEl?passEl.value:'';
  if(!pass){alert('Enter your sudo password to continue.');return;}
  r6pCloseInstallModal();
  /* Clear password from DOM immediately after reading */
  if(passEl)passEl.value='';

  if(!_r6pInstallToolList.length)return;
  var out=document.getElementById('r6p-preflight-out');
  if(out){out.style.display='block';out.textContent='Installing: '+_r6pInstallToolList.join(' ')+'\n';}

  var scriptPath='/home/dzoan/OSPC2FLEX/osflex-deployer-fullmig-5.0.0420current/workflow_dashboard/static/install-missing-cli-tools.sh';
  /* Write password to a locked temp file — never in the process list */
  var passEsc=pass.replace(/'/g,"'\\''");
  var tmpFile='/tmp/.r6p_sp_'+Date.now();
  /* Each sudo call inside the script pipes from the same temp file via _sudo().
     Temp file is deleted immediately after the script exits (success or failure). */
  var cmd="printf '%s' '"+passEsc+"' > '"+tmpFile+"' && chmod 600 '"+tmpFile+"'"
    +" && chmod +x '"+scriptPath+"'"
    +" && SUDO_PASS_FILE='"+tmpFile+"' bash '"+scriptPath+"' "+_r6pInstallToolList.join(' ')
    +"; _rc=$?; rm -f '"+tmpFile+"'; exit $_rc";

  var url='/api/stream/run-cmd?cmd='+encodeURIComponent(cmd);
  var es=new EventSource(url);
  var _done=false;
  es.onmessage=function(e){
    if(e.data==='[DONE]'){_done=true;es.close();setTimeout(r6pRunPreflight,800);return;}
    var line=e.data.replace(/r6p_sp_\d+/g,'[sudo-auth-file]');
    if(out){out.textContent+=line+'\n';out.scrollTop=out.scrollHeight;}
  };
  /* onerror fires when server closes the stream (normal after [DONE]) — ignore if already done */
  es.onerror=function(){if(!_done&&out)out.textContent+='[stream closed]\n';es.close();};
};

/* Credential cache — persists non-secret fields across sessions */
var R6P_CACHE_KEY='r6p_cred_cache';
var R6P_SECRET_FIELDS=[]; /* caching everything, incl. secrets, per explicit user request */

window.r6pRefreshCloudBadge=function(){
  var b=document.getElementById('r6p-cloud-badge'); if(!b) return;
  var st=R6P.creds.cloud.status;
  var hasCreds=!!((document.getElementById('r6p-c-username')||{}).value||(document.getElementById('r6p-c-credid')||{}).value);
  b.innerHTML = (st==='connected') ? '<span style="background:#dcfce7;color:#16a34a;padding:2px 10px;border-radius:999px;font-size:10px;font-weight:700;">Connected</span>'
    : (st==='failed') ? '<span style="background:#fee2e2;color:#dc2626;padding:2px 10px;border-radius:999px;font-size:10px;font-weight:700;">Failed</span>'
    : hasCreds ? '<span style="background:#fef3c7;color:#d97706;padding:2px 10px;border-radius:999px;font-size:10px;font-weight:700;">Configured</span>'
    : '<span style="background:#f1f5f9;color:#94a3b8;padding:2px 10px;border-radius:999px;font-size:10px;font-weight:700;">Not Configured</span>';
};
window.r6pSaveCredCache=function(){
  setTimeout(r6pRefreshCloudBadge,0);
  if(typeof r6pSaveCredsServer==='function')r6pSaveCredsServer();
  var cache={
    authUrl:   (document.getElementById('r6p-c-authurl')||{}).value||'',
    authType:  (document.getElementById('r6p-c-authtype')||{}).value||'appcred',
    credId:    (document.getElementById('r6p-c-credid')||{}).value||'',
    username:  (document.getElementById('r6p-c-username')||{}).value||'',
    password:  (document.getElementById('r6p-c-password')||{}).value||'',
    secret:    (document.getElementById('r6p-c-secret')||{}).value||'',
    proj:      (document.getElementById('r6p-c-proj')||{}).value||'',
    domain:    (document.getElementById('r6p-c-domain')||{}).value||'',
    region:    (document.getElementById('r6p-c-region')||{}).value||''
  };
  try{localStorage.setItem(R6P_CACHE_KEY,JSON.stringify(cache));}catch(e){}
  r6pRefreshCloudBadge();
};

window.r6pLoadCredCache=function(){
  var raw;
  try{raw=localStorage.getItem(R6P_CACHE_KEY);}catch(e){return;}
  if(!raw)return;
  var c;try{c=JSON.parse(raw);}catch(e){return;}
  function set(id,val){if(!val)return;var el=document.getElementById(id);if(el)el.value=val;}
  set('r6p-c-authurl',  c.authUrl);
  set('r6p-c-credid',   c.credId);
  set('r6p-c-username', c.username);
  set('r6p-c-password', c.password);
  set('r6p-c-secret',   c.secret);
  set('r6p-c-proj',     c.proj);
  set('r6p-c-domain',   c.domain);
  /* auth type dropdown + show correct fields */
  if(c.authType){
    var dt=document.getElementById('r6p-c-authtype');
    if(dt){dt.value=c.authType;r6pAuthTypeChange(c.authType);}
  }
  /* region dropdown */
  if(c.region){
    var rs=document.getElementById('r6p-c-region');
    if(rs){for(var i=0;i<rs.options.length;i++){if(rs.options[i].value===c.region){rs.selectedIndex=i;break;}}}
  }
  /* restore R6P state */
  R6P.creds.cloud.authUrl=c.authUrl||'';
  R6P.creds.cloud.authType=c.authType||R6P.creds.cloud.authType||'';
  R6P.creds.cloud.username=c.username||R6P.creds.cloud.username||'';
  R6P.creds.cloud.password=c.password||R6P.creds.cloud.password||'';
  R6P.creds.cloud.credId=c.credId||'';
  R6P.creds.cloud.secret=c.secret||R6P.creds.cloud.secret||'';
  R6P.creds.cloud.projectId=c.proj||'';
  R6P.creds.cloud.proj=c.proj||'';
  R6P.creds.cloud.domain=c.domain||R6P.creds.cloud.domain||'';
  R6P.creds.cloud.region=c.region||'';
  setTimeout(r6pRefreshCloudBadge,0);
};

/* Credential helpers */
window.r6pToggleCred=function(key){var el=document.getElementById('r6p-cred-'+key);if(el)el.style.display=el.style.display==='none'?'block':'none';};
window.r6pSaveCred=function(section,field,value){
  if(R6P.creds[section])R6P.creds[section][field]=value;
  /* persist non-secret fields immediately */
  if(R6P_SECRET_FIELDS.indexOf(field)<0)r6pSaveCredCache();
};
window.r6pGitopsMethodChange=function(m){
  var ssh=document.getElementById('r6p-gs-ssh-fields'),https=document.getElementById('r6p-gs-https-fields');
  if(ssh)ssh.style.display=m==='ssh'?'block':'none';
  if(https)https.style.display=m==='https'?'grid':'none';
  r6pSaveCred('gitops','method',m);
};

window.r6pTestCloud=function(done){
  function v(id){var el=document.getElementById(id);return el?el.value.trim():'';}
  var authUrl=v('r6p-c-authurl').replace(/\/+$/,'');
  var authType=v('r6p-c-authtype')||'password';
  var credId=v('r6p-c-credid'),secret=v('r6p-c-secret');
  var username=v('r6p-c-username'),password=v('r6p-c-password');
  var domain=v('r6p-c-domain')||'rackspace_cloud_domain';
  var proj=v('r6p-c-proj');
  var res=document.getElementById('r6p-cloud-result');

  if(!authUrl){if(res){res.style.color='#dc2626';res.textContent='Fill in Auth URL first.';}if(typeof done==='function')done({ok:false,reason:'not configured'});return;}

  /* Build Keystone v3 token request body — no shell, no CLI needed */
  var tokenUrl=authUrl+'/auth/tokens';
  var body,authDesc;

  if(authType==='appcred'){
    if(!credId||!secret){if(res){res.style.color='#dc2626';res.textContent='Fill Application Credential ID and Secret.';}if(typeof done==='function')done({ok:false,reason:'application credential incomplete'});return;}
    authDesc='v3 Application Credential';
    body={auth:{identity:{methods:['application_credential'],application_credential:{id:credId,secret:secret}}}};
  } else {
    if(!username||!password){if(res){res.style.color='#dc2626';res.textContent='Fill Username and Password.';}if(typeof done==='function')done({ok:false,reason:'username/password incomplete'});return;}
    var isV2=authUrl.indexOf('/v2')>=0;
    if(isV2){
      /* Rackspace v2 identity */
      tokenUrl=authUrl.replace(/\/v2.*$/,'')+'/v2.0/tokens';
      authDesc='v2 Password';
      body={auth:{passwordCredentials:{username:username,password:password},tenantId:proj||undefined}};
    } else {
      authDesc='v3 Password';
      var scope=proj?{project:{id:proj}}:{};
      body={auth:{identity:{methods:['password'],password:{user:{name:username,domain:{name:domain},password:password}}},scope:scope}};
    }
  }

  if(res){res.style.color='#d97706';res.textContent='Testing '+authDesc+' login...';}

  /* Use /api/uat/test-proxy — server-side POST, avoids CORS and shell quoting */
  fetch('/api/uat/test-proxy',{
    method:'POST',
    headers:{'Content-Type':'application/json'},
    body:JSON.stringify({url:tokenUrl,method:'POST',body:body,headers:{'Content-Type':'application/json'},timeout:12})
  })
  .then(function(r){return r.json();})
  .then(function(d){
    var ok=d.status===201||d.status===200||(d.ok&&d.body&&d.body.indexOf('token')>=0);
    R6P.creds.cloud.status=ok?'connected':'failed';r6pRefreshCloudBadge();
    if(res){
      res.style.color=ok?'#16a34a':'#dc2626';
      if(ok){
        var proj_info='';
        try{var t=JSON.parse(d.body);proj_info=' — project: '+(t.token&&t.token.project&&t.token.project.name||'');}catch(e){}
        res.textContent='Connected ('+authDesc+')'+proj_info;
      } else {
        var errMsg=d.body?d.body.substring(0,200):'HTTP '+d.status;
        res.textContent='Login failed ('+d.status+'): '+errMsg;
      }
    }
    if(typeof done==='function')done({ok:ok,status:d.status});
  })
  .catch(function(e){
    R6P.creds.cloud.status='failed';
    if(res){res.style.color='#dc2626';res.textContent='Request failed: '+(e.message||e);}
    if(typeof done==='function')done({ok:false,reason:e.message||String(e)});
  });
};

window.r6pTestOC=function(){
  var cluster=document.getElementById('r6p-oc-cluster')&&document.getElementById('r6p-oc-cluster').value||'rackspace-flex/flex-prod-k8s';
  var res=document.getElementById('r6p-oc-result');
  if(res){res.style.color='#d97706';res.textContent='Testing OpenCenter access...';}
  var cmd='opencenter cluster describe '+cluster+' 2>&1 | head -20';
  var url='/api/stream/run-cmd?cmd='+encodeURIComponent(cmd);
  var out='';var es=new EventSource(url);
  es.onmessage=function(e){
    if(e.data==='[DONE]'){es.close();
      var ok=out.indexOf('git_dir:')>=0||out.indexOf('cluster')>=0;
      R6P.creds.opencenter.status=ok?'connected':'failed';
      if(ok){var gd=out.match(/git_dir:\s*(\S+)/);if(gd){R6P.creds.opencenter.gitDir=gd[1];var el=document.getElementById('r6p-oc-gitdir');if(el)el.value=gd[1];}}
      if(res){res.style.color=ok?'#16a34a':'#dc2626';res.textContent=ok?'OpenCenter access confirmed. GitOps directory detected.':'OpenCenter access failed. Check CLI installation and login.';}
      return;
    }out+=e.data+'\n';
  };
  es.onerror=function(){es.close();if(res){res.style.color='#dc2626';res.textContent='OpenCenter CLI not found or connection error.';}};
};

window.r6pDetectGitDir=function(){
  var cluster=document.getElementById('r6p-oc-cluster')&&document.getElementById('r6p-oc-cluster').value||'rackspace-flex/flex-prod-k8s';
  var cmd='opencenter cluster describe '+cluster+' 2>/dev/null | grep "git_dir:" | awk \'{print $2}\'';
  var url='/api/stream/run-cmd?cmd='+encodeURIComponent(cmd);
  var es=new EventSource(url);var out='';
  es.onmessage=function(e){if(e.data==='[DONE]'){es.close();var gd=out.trim();if(gd){R6P.creds.opencenter.gitDir=gd;var el=document.getElementById('r6p-oc-gitdir');if(el)el.value=gd;}return;}out+=e.data;};
  es.onerror=function(){es.close();};
};

window.r6pTestGitOps=function(){
  var path=document.getElementById('r6p-gs-path')&&document.getElementById('r6p-gs-path').value||R6P.creds.opencenter.gitDir;
  var res=document.getElementById('r6p-gs-result');
  if(!path){if(res){res.style.color='#dc2626';res.textContent='Enter GitOps local directory or detect from OpenCenter first.';}return;}
  if(res){res.style.color='#d97706';res.textContent='Testing git access...';}
  var cmd='git -C "'+path+'" status 2>&1 && git -C "'+path+'" remote -v 2>&1 | head -4';
  var url='/api/stream/run-cmd?cmd='+encodeURIComponent(cmd);
  var out='';var es=new EventSource(url);
  es.onmessage=function(e){if(e.data==='[DONE]'){es.close();var ok=out.indexOf('On branch')>=0||out.indexOf('nothing to commit')>=0;R6P.creds.gitops.status=ok?'connected':'failed';if(res){res.style.color=ok?'#16a34a':'#dc2626';res.textContent=ok?'Git repo access confirmed.':'Git repo access failed. Check path or credentials.';}return;}out+=e.data+'\n';};
  es.onerror=function(){es.close();};
};

window.r6pRunGitopsCmd=function(sub){
  var path=R6P.creds.opencenter.gitDir||document.getElementById('r6p-gs-path')&&document.getElementById('r6p-gs-path').value;
  if(!path){alert('Set GitOps directory first.');return;}
  var cmds={status:'git -C "'+path+'" status',remote:'git -C "'+path+'" remote -v',fetch:'git -C "'+path+'" fetch --dry-run 2>&1'};
  var cmd=cmds[sub]||cmds.status;
  var out=document.getElementById('r6p-gc-out');if(out)out.style.display='block';
  var url='/api/stream/run-cmd?cmd='+encodeURIComponent(cmd);
  var es=new EventSource(url);es.onmessage=function(e){if(e.data==='[DONE]'){es.close();return;}if(out){out.textContent+=e.data+'\n';out.scrollTop=out.scrollHeight;}};
  es.onerror=function(){es.close();};
};

function r6pGCSet(id,ok,val){var st=document.getElementById(id+'-st'),v=document.getElementById(id+'-val');if(st){st.style.background=ok?'#dcfce7':'#fee2e2';st.style.color=ok?'#16a34a':'#dc2626';st.textContent=ok?'Pass':'Fail';}if(v)v.textContent=val||'—';}

window.r6pRunGitopsPreflight=function(done){
  var gitDir=R6P.creds.opencenter.gitDir||document.getElementById('r6p-gs-path')&&document.getElementById('r6p-gs-path').value;
  var out=document.getElementById('r6p-gc-out');if(out){out.style.display='block';out.textContent='';}
  var cmd='GD="'+(gitDir||'')+'"\n'
    +'[ -n "$GD" ] && [ -d "$GD" ] && echo "GITDIR:ok:$GD" || echo "GITDIR:fail:'+(gitDir?'not a real directory - '+gitDir:'empty')+'"\n'
    +'[ -n "$GD" ] && [ -d "$GD" ] && git -C "$GD" rev-parse --git-dir &>/dev/null && echo "ISREPO:ok" || echo "ISREPO:fail"\n'
    +'[ -n "$GD" ] && [ -d "$GD" ] && git -C "$GD" remote -v 2>/dev/null | grep -q fetch && echo "REMOTE:ok:$(git -C $GD remote get-url origin 2>/dev/null)" || echo "REMOTE:fail"\n'
    +'[ -n "$GD" ] && [ -d "$GD" ] && { [ -d "$GD/applications/overlays" ] || [ -d "$GD/applications/workloads" ]; } && echo "WORKLOADS:ok" || echo "WORKLOADS:fail:applications/overlays missing"\n'
    +'git config --global user.name &>/dev/null && echo "GITNAME:ok:$(git config --global user.name)" || echo "GITNAME:fail:not set"\n'
    +'git config --global user.email &>/dev/null && echo "GITEMAIL:ok:$(git config --global user.email)" || echo "GITEMAIL:fail:not set"\n'
    +'command -v flux &>/dev/null && echo "FLUX:ok:$(flux --version 2>/dev/null | head -1)" || echo "FLUX:fail:not installed"\n'
    +'CLN=$(opencenter cluster describe --output yaml 2>/dev/null | awk -F": " \'/^\\s*cluster_name:/{print $2; exit}\')\n'
    +'KCFG=""\n'
    +'[ -n "$GD" ] && [ -n "$CLN" ] && [ -f "$GD/infrastructure/clusters/$CLN/kubeconfig.yaml" ] && KCFG="$GD/infrastructure/clusters/$CLN/kubeconfig.yaml"\n'
    +'[ -z "$KCFG" ] && [ -n "$GD" ] && [ -d "$GD" ] && KCFG=$(find "$GD/infrastructure/clusters" -maxdepth 2 -name kubeconfig.yaml 2>/dev/null | head -1)\n'
    +'[ -n "$KCFG" ] && export KUBECONFIG="$KCFG"\n'
    +'if [ -z "$KCFG" ]; then echo "KUBECTL:fail:no kubeconfig found under \\$GD/infrastructure/clusters"\n'
    +'elif ! command -v kubectl &>/dev/null; then echo "KUBECTL:fail:kubectl not installed"\n'
    +'elif kubectl cluster-info 2>/dev/null | head -1 | grep -qi "running\\|is running at"; then echo "KUBECTL:ok:$KCFG"\n'
    +'else echo "KUBECTL:fail:cluster unreachable via $KCFG"; fi';
  var url='/api/stream/run-cmd?cmd='+encodeURIComponent(cmd);
  var es=new EventSource(url);
  var results={},finished=false;
  var finish=function(reason){if(finished)return;finished=true;try{es.close();}catch(e){}var required=['GITDIR','ISREPO','REMOTE','WORKLOADS','GITNAME','GITEMAIL','FLUX','KUBECTL'];var ok=required.every(function(k){return results[k]===true;});if(typeof done==='function')done({ok:ok,results:results,reason:reason||''});};
  es.onmessage=function(e){
    if(e.data==='[DONE]'||e.data.indexOf('[EXIT')===0){r6pCheckContinue();finish();return;}
    if(out){out.textContent+=e.data+'\n';out.scrollTop=out.scrollHeight;}
    var m=e.data.match(/^(GITDIR|ISREPO|REMOTE|WORKLOADS|GITNAME|GITEMAIL|FLUX|KUBECTL):(ok|fail):?(.*)?$/);
    if(!m)return;
    var key=m[1],ok=m[2]==='ok',val=m[3]||'';
    results[key]=ok;
    var map={GITDIR:'r6p-gc-gitdir',ISREPO:'r6p-gc-isrepo',REMOTE:'r6p-gc-remote',WORKLOADS:'r6p-gc-workloads',GITNAME:'r6p-gc-gituser',GITEMAIL:'r6p-gc-gitemail',FLUX:'r6p-gc-flux',KUBECTL:'r6p-gc-kubectl'};
    if(map[key])r6pGCSet(map[key],ok,val);
  };
  es.onerror=function(){finish('GitOps preflight stream error');};
};

window.r6pAutoRunStartupPreflight=function(){
  if(R6P.startupPreflightStarted)return;
  R6P.startupPreflightStarted=true;
  var out=document.getElementById('r6p-preflight-out');
  if(out){out.style.display='block';out.textContent='Automatic R6 startup checks\n1/3 CLI tools preflight running...\n';}
  r6pRunPreflight(function(cli){
    if(out){out.textContent+='\n2/3 Cloud login test '+(cli.ok?'starting':'starting (CLI issues remain)')+'...\n';out.scrollTop=out.scrollHeight;}
    r6pTestCloud(function(cloud){
      if(out){out.textContent+='\nCloud login: '+(cloud.ok?'PASS':'FAIL / NOT CONFIGURED')+'\n3/3 GitOps preflight starting...\n';out.scrollTop=out.scrollHeight;}
      r6pRunGitopsPreflight(function(gitops){
        R6P.startupPreflight={cli:cli,cloud:cloud,gitops:gitops,completedAt:new Date().toISOString()};
        if(out){out.textContent+='\nAutomatic startup checks complete — CLI '+(cli.ok?'PASS':'FAIL')+', Cloud '+(cloud.ok?'PASS':'FAIL')+', GitOps '+(gitops.ok?'PASS':'FAIL')+'.\nReview failures before continuing.\n';out.scrollTop=out.scrollHeight;}
      });
    });
  });
};

window.r6pTestKubectlLive=function(){
  var gitDir=R6P.creds.opencenter.gitDir||document.getElementById('r6p-git-localdir')&&document.getElementById('r6p-git-localdir').value;
  var out=document.getElementById('r6p-gc-out');if(out){out.style.display='block';out.textContent='';}
  var cmd='GD="'+(gitDir||'')+'"\n'
    +'CLN=$(opencenter cluster describe --output yaml 2>/dev/null | awk -F": " \'/^[[:space:]]*cluster_name:/{print $2; exit}\')\n'
    +'KCFG=""\n'
    +'[ -n "$GD" ] && [ -n "$CLN" ] && [ -f "$GD/infrastructure/clusters/$CLN/kubeconfig.yaml" ] && KCFG="$GD/infrastructure/clusters/$CLN/kubeconfig.yaml"\n'
    +'[ -z "$KCFG" ] && [ -n "$GD" ] && [ -d "$GD" ] && KCFG=$(find "$GD/infrastructure/clusters" -maxdepth 2 -name kubeconfig.yaml 2>/dev/null | head -1)\n'
    +'if [ -z "$KCFG" ]; then echo "No kubeconfig found yet for cluster \'$CLN\' under $GD/infrastructure/clusters - cluster is likely still bootstrapping."\n'
    +'else\n'
    +'  export KUBECONFIG="$KCFG"\n'
    +'  echo "== Using kubeconfig: $KCFG =="\n'
    +'  echo "== kubectl cluster-info =="\n'
    +'  timeout 10 kubectl cluster-info 2>&1\n'
    +'  echo "== kubectl get nodes -o wide =="\n'
    +'  timeout 10 kubectl get nodes -o wide 2>&1\n'
    +'fi';
  var url='/api/stream/run-cmd?cmd='+encodeURIComponent(cmd);
  var es=new EventSource(url);
  es.onmessage=function(e){
    if(e.data==='[DONE]'||e.data.indexOf('[EXIT')===0){es.close();return;}
    if(out){out.textContent+=e.data+'\n';out.scrollTop=out.scrollHeight;}
  };
  es.onerror=function(){es.close();if(out)out.textContent+='[stream error]\n';};
};

window.r6pParseSshTarget=function(raw,component){
  var value=String(raw||'').trim(), host='';
  try{
    var parsed=new URL(value.indexOf('://')>=0?value:'ssh://'+value);
    host=parsed.hostname;
  }catch(e){
    host=value.replace(/^[a-z][a-z0-9+.-]*:\/\//i,'').split('/')[0].split(':')[0];
  }
  host=host.replace(/^\[|\]$/g,'');
  var sshPort=parseInt((component&&(
    component.sshPort||component.ssh_port||
    (component.ssh&&component.ssh.port)))||22,10);
  if(!host||!/^[a-z0-9._:-]+$/i.test(host))return null;
  if(!Number.isInteger(sshPort)||sshPort<1||sshPort>65535)sshPort=22;
  return {host:host,port:sshPort,source:value};
};
window.r6pShellQuote=function(value){
  return "'"+String(value).replace(/'/g,"'\"'\"'")+"'";
};
window.r6pHtml=function(value){
  return String(value==null?'':value).replace(/[&<>"']/g,function(ch){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch];});
};
window.r6pProductionScanTerminal=function(){
  var value=R6P.productionScanLog||'Live scan output will appear here after Run Scan is selected.';
  return '<div class="r6p-scan-terminal-wrap" style="margin:-4px 0 14px;"><div style="font-size:11px;font-weight:800;color:#334155;margin-bottom:4px;">Verbose live scan output</div><pre id="r6p-production-scan-status" class="r6p-terminal" data-terminal-output style="display:block;min-height:180px;max-height:420px;overflow:auto;white-space:pre-wrap;">'+r6pHtml(value)+'</pre></div>';
};
window.r6pSetProductionScanLog=function(value,append){
  R6P.productionScanLog=append&&R6P.productionScanLog?R6P.productionScanLog+'\n'+String(value||''):String(value||'');
  var out=document.getElementById('r6p-production-scan-status');
  if(out){out.style.display='block';out.textContent=R6P.productionScanLog;out.scrollTop=out.scrollHeight;}
  if(R6P.structuredAppraisal&&R6P.structuredAppraisal.runId)r6pPersistScanView(R6P.structuredAppraisal);
};
window.r6pFormatProductionScanLog=function(run){
  var p=run.progress||{},events=run.liveLog||[],lines=['=== R6 VERBOSE COMPONENT SCAN ===','Run: '+run.runId,'Business System: '+((run.businessSystem&&run.businessSystem.name)||'unknown'),'Status: '+run.status,'Started: '+(run.startedAt||'unknown'),'Updated: '+new Date().toISOString(),'Components: '+(p.completedComponents||0)+' / '+(p.totalComponents||0),'Diagnostic events: '+events.length];
  if(run.completedAt)lines.push('Completed: '+run.completedAt);
  if(run.currentComponent)lines.push('Current component: '+run.currentComponent);
  if(p.currentProbe)lines.push('Current probe: '+p.currentProbe+' '+(p.currentProbeName||'')+' ('+(p.completedProbes||0)+' / '+(p.totalProbes||20)+')');
  lines.push('');
  events.forEach(function(e,index){
    var prefix='['+(e.timestamp||'')+'] ['+(e.level||'INFO')+']';
    if(e.component)prefix+=' ['+e.component+']';
    if(e.probeId)prefix+=' ['+e.probeId+' '+(e.probeName||'')+']';
    lines.push('--- EVENT '+(index+1)+' / '+events.length+' ---');
    lines.push(prefix+' '+(e.message||'')+(e.status?' — '+e.status:'')+(e.commandIdentifier?' command='+e.commandIdentifier:'')+(e.exitCode!=null?' exit='+e.exitCode:'')+(e.durationMs!=null?' duration='+e.durationMs+'ms':''));
    if(e.targetHost)lines.push('  target: '+e.targetHost+':'+(e.targetPort||22)+(e.sourceVmId?' source-vm='+e.sourceVmId:''));
    if(e.phase)lines.push('  phase: '+e.phase);
    if(e.startedAt)lines.push('  started: '+e.startedAt);
    if(e.completedAt)lines.push('  completed: '+e.completedAt);
    if(e.timeoutSeconds!=null)lines.push('  timeout limit: '+e.timeoutSeconds+'s');
    if(e.timeout!=null||e.truncated!=null||e.evidenceCount!=null)lines.push('  timeout='+(e.timeout?'yes':'no')+' truncated='+(e.truncated?'yes':'no')+' evidence-lines='+(e.evidenceCount==null?'0':e.evidenceCount));
    if(e.probeId&&e.status!=='RUNNING')lines.push('  STDOUT:\n    '+(e.stdout?String(e.stdout).replace(/\n/g,'\n    '):'<empty>'));
    if(e.probeId&&e.status!=='RUNNING')lines.push('  STDERR:\n    '+(e.stderr?String(e.stderr).replace(/\n/g,'\n    '):'<empty>'));
    if(e.remediation)lines.push('  recommended action: '+e.remediation);
  });
  if(!(run.liveLog||[]).some(function(e){return e.probeId;})){
    (run.components||[]).forEach(function(c){
      lines.push('\n=== COMPONENT '+c.componentName+' — '+c.componentVerdict+' ===');
      (c.probes||[]).forEach(function(e){
        lines.push('['+(e.completedAt||'')+'] ['+e.status+'] ['+e.probeId+' '+e.probeName+'] command='+(e.commandIdentifier||e.probeId)+' exit='+e.exitCode+' duration='+e.durationMs+'ms');
        lines.push('  started: '+(e.startedAt||'unknown')+'\n  completed: '+(e.completedAt||'unknown')+'\n  timeout='+(e.timeout?'yes':'no')+' truncated='+(e.truncated?'yes':'no')+' evidence-lines='+(e.evidenceCount||0));
        if(e.stdout)lines.push('  STDOUT:\n    '+String(e.stdout).replace(/\n/g,'\n    '));
        if(e.stderr)lines.push('  STDERR:\n    '+String(e.stderr).replace(/\n/g,'\n    '));
        if(e.remediation)lines.push('  recommended action: '+e.remediation);
      });
    });
  }
  return lines.join('\n');
};
window.r6pRootCauseRecommendedActions=function(x){
  var code=x&&x.errorCode||"";
  var defaults={
    PRIVATE_KEY_CAPTURE_PATH:["Remove or relocate the private key out of the application/capture path.","Rotate or re-issue the key after migration; do not bake it into an image.","Exclude the path from capture and retry this component."],
    PLAINTEXT_SECRET:["Externalize the plaintext secret into the target secret manager and rotate it.","Block container build until the secret is removed from captured source."],
    PLAINTEXT_SECRET_HARDCODED:["Move hardcoded credentials to environment or secret manager injection.","Rotate the exposed credential before package generation."],
    SSH_HOST_KEY_CHANGED:["Verify the new fingerprint with the infrastructure owner.","Use Verify and Replace Key to update only the managed known_hosts entry, then retry the VM."],
    COMPONENT_VM_MAPPING_MISSING:["Open Stage 1 and map this component to the correct OpenStack server UUID.","Set FLEX Target IP/URL or source VM UUID, save the Business System, then retry this component."],
    DATABASE_ENDPOINT_UNREACHABLE:["Verify the database service is listening on the configured host and port from the scanner network.","Check FLEX/security-group/firewall rules for TCP database access, then retry the database component.","If this is an externally managed database, switch the component to a managed/native database access mode and provide reachability metadata."]
  };
  var summary=String((x&&x.summary)||"").trim();
  var actions=(x&&x.recommendedActions||[]).filter(Boolean).map(function(a){return String(a).trim();}).filter(function(a){return a&&a!==summary;});
  if((!actions.length||code==='DATABASE_ENDPOINT_UNREACHABLE')&&defaults[code])actions=defaults[code];
  return actions.length?actions:["Review diagnostics, correct the source configuration, then retry the affected component."];
};
window.r6pFailedChecksTable=function(run){
  var roots=run&&run.appraisal&&run.appraisal.rootCauses||[];
  if(!roots.length)(run&&run.components||[]).forEach(function(c){(c.probes||[]).forEach(function(p){if(p.status==='FAIL'||p.status==='BLOCKED')roots.push({componentId:c.componentId,componentName:c.componentName,sourceVmId:c.sourceVmId,probeId:p.probeId,errorCode:p.errorCode,summary:p.diagnosticSummary||p.stderr||p.stdout,recommendedActions:p.recommendedActions||[p.remediation],skippedChecks:(c.probes||[]).filter(function(s){return s.derivedFrom===p.rootCauseId;}).length});});});
  return '<section class="r6p-failed-checks" style="margin:16px 0;border:1px solid #fecaca;border-radius:9px;padding:12px;background:#fff;"><div style="display:flex;justify-content:space-between;align-items:center;gap:8px;flex-wrap:wrap;"><div><h3 style="margin:0;">Failed Checks by Components — Root Causes</h3><div style="font-size:11px;color:#64748b;">Prerequisite-skipped probes are collapsed beneath their root cause and are not counted as independent blockers.</div></div><div style="display:flex;gap:6px;"><button class="r6p-btn secondary" onclick="r6pRetryAllFailed()">Retry All Failed</button><button class="r6p-btn secondary" onclick="r6pExportFailedChecksCsv()">Export Root Causes CSV</button></div></div><div style="overflow:auto;margin-top:10px;"><table class="r6p-table"><thead><tr><th>Component / VM</th><th>Root cause</th><th>Details / impact</th><th>Recommended actions</th><th>Retry</th></tr></thead><tbody>'+(roots.length?roots.map(function(x){var actions=r6pRootCauseRecommendedActions(x),fingerprints=x.errorCode==='SSH_HOST_KEY_CHANGED'?'<br><b>Target:</b> '+r6pHtml(x.targetHost||'unknown')+'<br><b>Old key:</b> '+r6pHtml(x.oldFingerprint||'not reported')+'<br><b>New key:</b> '+r6pHtml(x.newFingerprint||'not reported'):'';return '<tr><td><b>'+r6pHtml(x.componentName)+'</b><br>'+r6pHtml(x.sourceVmId||'unmapped')+'</td><td><b style="color:#dc2626;">'+r6pHtml(x.errorCode||x.probeId||'SCAN_FAILURE')+'</b><br>'+r6pHtml(x.probeId||'')+'</td><td style="max-width:390px;white-space:pre-wrap;">'+r6pHtml(x.summary||'No diagnostic summary returned.')+fingerprints+'<br><b>Impact:</b> '+r6pHtml(x.skippedChecks||0)+' dependent checks skipped</td><td>'+r6pHtml(actions.join(' • ')||'Review diagnostics and retry.')+'</td><td><button class="r6p-btn secondary" onclick="r6pRetryAppraisal(\''+r6pHtml(x.componentId)+'\')">Retry Component</button>'+(x.sourceVmId?'<button class="r6p-btn secondary" style="margin-top:4px;" onclick="r6pRetryVm(\''+r6pHtml(x.sourceVmId)+'\')">Retry VM</button>':'')+(x.errorCode==='SSH_HOST_KEY_CHANGED'?'<button class="r6p-btn secondary" style="margin-top:4px;" onclick="r6pVerifyReplaceHostKey(\''+r6pHtml(x.componentId)+'\')">Verify and Replace Key</button>':'')+'</td></tr>';}).join(''):'<tr><td colspan="5">No root failures or blockers.</td></tr>')+'</tbody></table></div></section>';
};
window.r6pAppraisalAllowsStage8=function(c){
  var a=r6pFindComponentAppraisal(c);
  if(!a)return false;
  return ['READY_FOR_STAGE_8','DB_NATIVE_REQUIRED','RETAIN_VM_RECOMMENDED'].indexOf(a.componentVerdict)>=0||
    (a.componentVerdict==='READY_FOR_STAGE_8_WITH_WARNINGS'&&R6P.appraisalReviewed===true);
};
window.r6pProductionScanPayloadLegacy=function(){
  var user=((document.getElementById('r6p-scan-user')||{}).value||'').trim();
  var key=((document.getElementById('r6p-scan-key')||{}).value||'').trim();
  var known=((document.getElementById('r6p-scan-known-hosts')||{}).value||'./data/ssh/known_hosts').trim();
  var all=(R6P.components||[]);
  var scope=(document.getElementById('r6p-scan-comp')||{}).value||'__all__';
  var selected=scope==='__all__'?all:(all[parseInt(scope,10)]?[all[parseInt(scope,10)]]:[]);
  return {businessSystem:{id:R6P.bs&&R6P.bs.id,name:R6P.bs&&R6P.bs.name,totalComponentCount:all.length,scanScope:scope==='__all__'?'ALL_COMPONENTS':'SINGLE_COMPONENT',components:selected.map(function(c){var ep=r6pParseSshTarget(r6pComponentTarget(c),c),mapped=r6pResolveComponentVm(c),vmId=mapped.id,dbMode=c.databaseAccessMode||c.database_access_mode||c.databaseTargetType||((/database|db/i.test(c.type||c.role||c.name||'')&&!vmId)?'UNKNOWN':null);return{id:c.id||c.name,name:c.name,sourceVmId:vmId,source_vm_id:vmId,sourceVmName:c.sourceVmName||c.source_vm_name||c.vmName||c.vm_name||mapped.name||null,sourceIp:(ep&&ep.host)||c.sourceIp||c.source_ip||mapped.ip||null,sshHost:ep&&ep.host,sshPort:ep&&ep.port,sshUser:c.sshUser||c.ssh_user||user,cloudRegion:c.cloudRegion||c.cloud_region||mapped.region||R6P.bs&&R6P.bs.region||null,scanTargetId:c.scanTargetId||c.scan_target_id||vmId,expectedFingerprint:c.expectedFingerprint||c.sshFingerprint||null,type:c.type||c.role||'',databaseAccessMode:dbMode,databaseEndpoint:c.databaseEndpoint||r6pComponentTarget(c),cloudInventory:c.cloudInventory||c.cloud_inventory||null,volumeIds:c.volumeIds||c.volume_ids||[]};})},ssh:{user:user,keyPath:key,knownHostsFile:known}};
};
window.r6pProductionScanPayload=function(){
  var user=((document.getElementById('r6p-scan-user')||{}).value||'').trim();
  var key=((document.getElementById('r6p-scan-key')||{}).value||'').trim();
  var known=((document.getElementById('r6p-scan-known-hosts')||{}).value||'./data/ssh/known_hosts').trim();
  var all=(R6P.components||[]),scope=(document.getElementById('r6p-scan-comp')||{}).value||'__all__';
  var selected=scope==='__all__'?all:(all[parseInt(scope,10)]?[all[parseInt(scope,10)]]:[]);
  var components=selected.map(function(c){
    var ep=r6pParseSshTarget(r6pComponentTarget(c),c),mapped=r6pResolveComponentVm(c),vmId=mapped.id;
    var input=r6pInputConnectionFor(c),isDb=/database|db/i.test((c.type||c.role||'')+' '+(c.name||''));
    var serviceEndpoint=r6pParseTargetEndpoint(r6pComponentTarget(c)),healthPath=String(c.path||c.healthPath||c.health_path||'').split(',')[0];
    var dbMode=c.databaseAccessMode||c.database_access_mode||c.databaseTargetType||(isDb&&!vmId?(input.sshConfigured?'VM_SSH':'UNKNOWN'):null);
    /* A stale UNKNOWN saved by an older UI must not suppress newly saved Input SSH credentials. */
    if(isDb&&input.sshConfigured&&String(dbMode||'').toUpperCase()==='UNKNOWN')dbMode='VM_SSH';
    return {id:c.id||c.name,name:c.name,sourceVmId:vmId,source_vm_id:vmId,
      sourceVmName:c.sourceVmName||c.source_vm_name||c.vmName||c.vm_name||mapped.name||null,
      sourceIp:(ep&&ep.host)||c.sourceIp||c.source_ip||mapped.ip||null,sshHost:ep&&ep.host,sshPort:ep&&ep.port,
      sshUser:input.sshUser||user,sshKeyPath:input.sshKeyPath||key,
      cloudRegion:c.cloudRegion||c.cloud_region||mapped.region||R6P.bs&&R6P.bs.region||null,
      scanTargetId:c.scanTargetId||c.scan_target_id||vmId,expectedFingerprint:c.expectedFingerprint||c.sshFingerprint||null,
      type:c.type||c.role||'',databaseEngine:input.databaseEngine,databaseAccessMode:dbMode,
      databaseEndpoint:input.databaseEndpoint||c.databaseEndpoint||r6pComponentTarget(c),
      healthPath:healthPath&&healthPath.charAt(0)==='/'?healthPath:null,applicationPort:serviceEndpoint&&serviceEndpoint.port,
      cloudInventory:c.cloudInventory||c.cloud_inventory||null,vmStatus:c.vmStatus||c.vm_status||null,
      bootSource:c.bootSource||c.boot_source||null,volumeIds:c.volumeIds||c.volume_ids||[]};
  });
  return {businessSystem:{id:R6P.bs&&R6P.bs.id,name:R6P.bs&&R6P.bs.name,totalComponentCount:all.length,scanScope:scope==='__all__'?'ALL_COMPONENTS':'SINGLE_COMPONENT',components:components},ssh:{user:user,keyPath:key,knownHostsFile:known}};
};
window.r6pSetScanUiVersion=function(version){
  var known=R6_SCAN_UI_VERSIONS.some(function(v){return v.id===version;});
  if(!known){alert('Unknown scan interface version: '+version);return;}
  R6P.scanUiVersion=version;
  var persisted=false;
  try{
    localStorage.setItem('r6p_scan_ui_version',version);
    sessionStorage.setItem('r6p_scan_ui_reopen_stage','3');
    persisted=true;
  }catch(e){}
  /* Reloading guarantees that all version-specific markup and assets start
     cleanly. The persisted run id is polled after Stage 3 reopens; this never
     starts, stops or duplicates a scan. Fall back to an in-place switch only
     when browser storage is unavailable. */
  if(!persisted){r6pApplyScanUiVersion();return;}
  window.setTimeout(function(){window.location.reload();},80);
};
window.r6pApplyScanUiVersion=function(){
  var body=document.getElementById('r6p-body-3'),host=body&&body.querySelector('.r6p-stage-body-inner');if(!host)return;
  host.innerHTML=r6pContent(3);
  if(R6P.structuredAppraisal)r6pRenderProductionAppraisal(R6P.structuredAppraisal);
};
window.r6pScanScopeChanged=function(){
  var sel=document.getElementById('r6p-scan-comp'),btn=document.getElementById('r6p-full-scan-btn');if(!sel||!btn)return;
  btn.innerHTML='&#9654; Run Scan';
  if(sel.value==='__all__')return;
  var c=(R6P.components||[])[parseInt(sel.value,10)],input=r6pInputConnectionFor(c||{});
  var userEl=document.getElementById('r6p-scan-user'),keyEl=document.getElementById('r6p-scan-key');
  if(userEl&&input.sshUser)userEl.value=input.sshUser;
  if(keyEl&&input.sshKeyPath)keyEl.value=input.sshKeyPath;
};
window.r6pStartProductionScan=function(){
  var payload=r6pProductionScanPayload(),out=document.getElementById('r6p-production-scan-status');
  payload.requestId='r6-scan-'+Date.now()+'-'+Math.random().toString(16).slice(2);
  if(!payload.businessSystem.components.length){alert('Select a Business System with FLEX target IPs first.');return;}
  var requiresSsh=payload.businessSystem.components.some(function(c){return ['MANAGED_DATABASE','KUBERNETES_SERVICE','PRIVATE_ENDPOINT','UNKNOWN'].indexOf(String(c.databaseAccessMode||'').toUpperCase())<0;});
  if(requiresSsh&&(!payload.ssh.user||!payload.ssh.keyPath)){alert('SSH user and key path are required for VM-hosted components.');return;}
  r6pSetProductionScanLog('Starting structured scan...');
  var button=document.getElementById('r6p-full-scan-btn');if(button)button.disabled=true;
  var send=function(attempt){
    fetch('/api/r6/scans/business-system/run',{method:'POST',headers:{'Content-Type':'application/json','Accept':'application/json'},cache:'no-store',body:JSON.stringify(payload)})
    .then(function(r){return r.text().then(function(text){
      var data;
      try{data=text?JSON.parse(text):{};}catch(e){throw new Error('Scan API returned HTTP '+r.status+' with a non-JSON response');}
      if(!r.ok||!data.ok)throw new Error(data.error||('Scan API returned HTTP '+r.status));
      return data;
    });})
    .then(function(data){
      R6P.scanRunId=data.runId;r6pRememberScanRun(data.runId);R6P.appraisalReviewed=false;
      var stop=document.getElementById('r6p-stop-scan-btn');if(stop)stop.disabled=false;
      r6pPollProductionScan();
    })
    .catch(function(error){
      if(attempt<2&&/Failed to fetch|NetworkError|Load failed/i.test(error.message||'')){
        r6pSetProductionScanLog('Scan API connection interrupted; retrying '+(attempt+1)+'/2...');
        setTimeout(function(){send(attempt+1);},600*(attempt+1));
        return;
      }
      r6pSetProductionScanLog('Scan start failed at '+window.location.origin+': '+error.message);
      if(button)button.disabled=false;
    });
  };
  send(0);
};
window.r6pPollProductionScan=function(){
  if(!R6P.scanRunId)return;
  fetch('/api/r6/scans/runs/'+encodeURIComponent(R6P.scanRunId),{cache:'no-store',headers:{'Cache-Control':'no-cache','Accept':'application/json'}}).then(function(r){
    return r.text().then(function(text){
      var data;
      try{data=text?JSON.parse(text):{};}catch(e){throw new Error('Scan refresh returned HTTP '+r.status+' with a non-JSON response');}
      if(!r.ok)throw new Error(data.error||('Scan refresh returned HTTP '+r.status));
      return data;
    });
  }).then(function(run){
    if(!run.ok)throw new Error(run.error||'run unavailable');
    if(R6P.bs&&run.businessSystem&&run.businessSystem.id&&String(run.businessSystem.id)!==String(R6P.bs.id)){R6P.scanRunId=null;R6P.structuredAppraisal=null;throw new Error('saved scan belongs to a different Business System');}
    r6pCacheScanRun(run);
    var p=run.progress||{},out=document.getElementById('r6p-production-scan-status');
    r6pSetProductionScanLog(r6pFormatProductionScanLog(run));
    R6P.structuredAppraisal=run;r6pRenderProductionAppraisal(run);r6pPersistScanView(run);
    if(run.status==='RUNNING'){window.clearTimeout(R6P.scanPollTimer);R6P.scanPollTimer=window.setTimeout(r6pPollProductionScan,1500);return;}
    var button=document.getElementById('r6p-full-scan-btn'),stop=document.getElementById('r6p-stop-scan-btn');if(button)button.disabled=false;if(stop)stop.disabled=true;
    if(run.appraisal){R6P.structuredAppraisal=run;r6pAdoptStructuredEvidence(run);r6pRenderProductionAppraisal(run);}
  }).catch(function(error){
    r6pSetProductionScanLog('Live refresh interrupted: '+error.message+'; retrying...',true);
    window.clearTimeout(R6P.scanPollTimer);
    if(R6P.scanRunId)R6P.scanPollTimer=window.setTimeout(r6pPollProductionScan,1500);
  });
};
window.r6pRefreshAppraisal=function(){if(!R6P.scanRunId)r6pRestoreScanRun();else r6pPollProductionScan();if(!R6P.scanRunId)alert('No saved scan run exists for this Business System.');};
window.r6pStopProductionScan=function(){if(!R6P.scanRunId)return;fetch('/api/r6/scans/runs/'+encodeURIComponent(R6P.scanRunId)+'/cancel',{method:'POST'}).then(function(){r6pPollProductionScan();});};
window.r6pExportProductionScan=function(){var id=R6P.scanRunId||localStorage.getItem('r6p_latest_scan_run');if(!id){alert('Run a scan first.');return;}window.location='/api/r6/scans/runs/'+encodeURIComponent(id)+'/export';};
window.r6pExportAllAppraisalsCsv=function(){var id=R6P.scanRunId||localStorage.getItem('r6p_latest_scan_run');if(!id){alert('Run a scan first.');return;}window.location='/api/r6/scans/runs/'+encodeURIComponent(id)+'/appraisals.csv';};
window.r6pExportAppraisalCsv=function(componentId){var id=R6P.scanRunId||localStorage.getItem('r6p_latest_scan_run');if(!id||!componentId){alert('Open a completed appraisal first.');return;}window.location='/api/r6/scans/runs/'+encodeURIComponent(id)+'/components/'+encodeURIComponent(componentId)+'/appraisal.csv';};
window.r6pExportFailedChecksCsv=function(){var id=R6P.scanRunId||localStorage.getItem('r6p_latest_scan_run');if(!id){alert('Run a scan first.');return;}window.location='/api/r6/scans/runs/'+encodeURIComponent(id)+'/failed-checks.csv';};
window.r6pAdoptStructuredEvidence=function(run){
  R6P.depScan=R6P.depScan||{};
  (run.components||[]).forEach(function(a){
    var source=(R6P.components||[]).find(function(c){
      var id=c.id||c.componentId||c.component_id;
      return (id&&id===a.componentId)||c.name===a.componentName||(c.previousNames||[]).indexOf(a.componentName)>=0;
    });
    var key=source&&source.name||a.componentName;
    R6P.depScan[key]={status:a.componentVerdict,completed:['READY_FOR_STAGE_8','DB_NATIVE_REQUIRED','RETAIN_VM_RECOMMENDED'].indexOf(a.componentVerdict)>=0,structured:true,runId:run.runId,appraisal:a,rawLog:(a.probes||[]).map(function(p){return p.probeId+' '+p.status+'\n'+(p.stdout||'')+'\n'+(p.stderr||'');}).join('\n')};
  });
  if(run.appraisal&&['READY','READY_FOR_STAGE_8'].indexOf(run.appraisal.finalVerdict)>=0)R6P.appraisalReviewed=true;
  if(typeof r6pRefreshComponentDrivenStages==='function')r6pRefreshComponentDrivenStages();
};
window.r6pReviewAppraisal=function(){
  var a=R6P.structuredAppraisal&&R6P.structuredAppraisal.appraisal;if(!a)return;
  if(['BLOCKED','BLOCKED_INFRASTRUCTURE','BLOCKED_SECURITY','BLOCKED_APPLICATION','SCAN_FAILED','SCAN_ERROR'].indexOf(a.finalVerdict)>=0||a.databaseReadiness==='BLOCKED'){alert('Blocked or failed appraisals cannot be approved. Resolve the failed checks first.');return;}
  if(confirm('Record review of warnings/manual findings and allow eligible components to continue to classification?')){R6P.appraisalReviewed=true;r6pAdoptStructuredEvidence(R6P.structuredAppraisal);r6pRenderProductionAppraisal(R6P.structuredAppraisal);}
};
window.r6pRenderProductionAppraisal=function(run){
  var root=document.getElementById('r6p-scan-appraisal'),verdictRoot=document.getElementById('r6p-scan-final-verdict'),failedRoot=document.getElementById('r6p-scan-failed-checks');if(!root)return;var a=run.appraisal;
  if(!a){root.innerHTML='<div class="r6p-info-box">Scan running. Completed component appraisals appear below.</div>';}
  var color=function(v){return /BLOCKED|FAILED|ERROR/.test(v)?'#dc2626':/WARNING|PARTIAL|MORE_EVIDENCE|REVIEW/.test(v)?'#d97706':/DB_NATIVE/.test(v)?'#2563eb':/RETAIN/.test(v)?'#7c3aed':'#16a34a';};
  var dimensions=a?'<div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(155px,1fr));gap:7px;margin-top:10px;">'+[['Discovery Coverage',a.discoveryCoveragePercent+'%'],['Infrastructure Access',a.infrastructureAccessStatus],['Application Readiness',a.applicationReadiness],['Database Readiness',a.databaseReadiness],['Snapshot Readiness',a.snapshotReadiness],['Containerization Readiness',a.containerizationReadiness]].map(function(x){return '<div style="background:#f8fafc;border:1px solid #e2e8f0;border-radius:7px;padding:8px;"><span style="font-size:10px;color:#64748b;">'+x[0]+'</span><br><b>'+r6pHtml(x[1])+'</b></div>';}).join('')+'</div>':'';
  var reviewBanner=a&&((a.rootCauses||[]).length||(a.systemWarnings||[]).length||a.finalVerdict==='REVIEW_REQUIRED'||a.finalVerdict==='READY_WITH_WARNINGS')?'<div style="border:2px solid '+(a.databaseReadiness==='BLOCKED'?'#dc2626':'#d97706')+';background:'+(a.databaseReadiness==='BLOCKED'?'#fef2f2':'#fffbeb')+';border-radius:10px;padding:14px;margin-bottom:14px;"><div style="font-size:14px;font-weight:900;color:'+(a.databaseReadiness==='BLOCKED'?'#b91c1c':'#92400e')+';">'+(a.databaseReadiness==='BLOCKED'?'ACTION REQUIRED - APPRAISAL BLOCKED':'REVIEW REQUIRED BEFORE CONTINUING')+'</div><div style="font-size:12px;margin-top:6px;">'+r6pHtml(((a.rootCauses||[])[0]||{}).summary||(a.systemWarnings||[])[0]||a.reason||'Review the appraisal findings.')+'</div><div style="font-size:12px;margin-top:5px;"><b>Next action:</b> '+r6pHtml(a.nextAction||'Review findings and retry affected checks.')+'</div>'+(a.databaseReadiness!=='BLOCKED'?'<button class="r6p-btn secondary" onclick="r6pReviewAppraisal()" style="margin-top:9px;">'+(R6P.appraisalReviewed?'Review Recorded':'Review Findings')+'</button>':'')+'</div>':'';
  var summary=a?reviewBanner+'<div style="border:2px solid '+color(a.finalVerdict)+';border-radius:10px;padding:14px;margin-bottom:14px;background:#fff;"><div style="display:flex;justify-content:space-between;gap:10px;align-items:flex-start;"><div><h3 style="margin:0 0 4px;">Business System Final Verdict</h3><div style="font-size:12px;color:#64748b;">'+r6pHtml(a.businessSystemName||'Business Apps System')+'</div></div><span style="color:'+color(a.finalVerdict)+';font-weight:900;">'+r6pHtml(a.finalVerdict)+'</span></div><div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(110px,1fr));gap:8px;margin-top:12px;">'+[['Components',a.summary.components],['Source VMs',a.summary.sourceVms],['Completed / applicable',(a.evidenceCoverage&&a.evidenceCoverage.completed||0)+' / '+(a.evidenceCoverage&&a.evidenceCoverage.applicable||0)],['Skipped',a.evidenceCoverage&&a.evidenceCoverage.skipped||0],['N/A',a.evidenceCoverage&&a.evidenceCoverage.notApplicable||0],['DB native',a.summary.databaseNative],['Blocked',a.summary.blocked],['Coverage',a.discoveryCoveragePercent+'%']].map(function(x){return '<div style="background:#f8fafc;border:1px solid #e2e8f0;border-radius:7px;padding:8px;text-align:center;"><b>'+r6pHtml(x[1])+'</b><div style="font-size:10px;color:#64748b;">'+x[0]+'</div></div>';}).join('')+'</div>'+dimensions+'<div style="margin-top:10px;font-size:12px;"><b>Reason:</b> '+r6pHtml(a.reason||'')+'</div><div style="margin-top:6px;font-size:12px;"><b>Recommended fix / next action:</b> '+r6pHtml(a.nextAction)+'</div></div>':'';
  var cards=(run.components||[]).map(function(c){var ps=c.probeSummary||{},ssh=(c.probes||[]).find(function(p){return p.probeId==='SCAN-001';})||{};return '<div style="border:1px solid #cbd5e1;border-top:4px solid '+color(c.componentVerdict)+';border-radius:9px;background:#fff;padding:13px;"><div style="display:flex;justify-content:space-between;gap:8px;"><strong>'+r6pHtml(c.componentName)+'</strong><span style="font-size:10px;color:'+color(c.componentVerdict)+';font-weight:900;">'+r6pHtml(c.componentVerdict)+'</span></div><div style="font-size:11px;color:#475569;margin:5px 0;">Mapped source VM: <b>'+r6pHtml(c.sourceVmName||c.sourceVmId||'unmapped')+'</b><br>Target IP: '+r6pHtml(c.sourceHost||c.sourceIp||'not mapped')+'<br>Access status: '+r6pHtml(ssh.status||'NOT_TESTED')+'<br>Completed checks: '+r6pHtml((ps.completed||0)+' / '+(ps.applicable||0))+' &bull; Warnings: '+r6pHtml((ps.warning||0)+(ps.passWithWarning||0))+' &bull; Root blockers: '+r6pHtml((c.blockers||[]).length)+'<br>Last scan: '+r6pHtml(c.probes&&c.probes.length?c.probes[c.probes.length-1].completedAt:'Never')+'</div><div style="display:flex;gap:12px;font-size:12px;"><b>Readiness '+c.containerReadinessScore+'%</b><b>Coverage '+c.discoveryCoveragePercent+'%</b></div><div style="font-size:11px;margin-top:8px;">Runtime: '+r6pHtml((c.runtime&&c.runtime.type)||'unknown')+' &bull; Ports: '+r6pHtml((c.ports||[]).join(', ')||'none')+'<br>Capture: '+r6pHtml(c.captureRecommendation)+'<br>Recommendation: '+r6pHtml(c.containerizationRecommendation)+'</div><div style="font-size:11px;margin-top:7px;color:#64748b;">'+(ps.pass||0)+' pass &bull; '+((ps.warning||0)+(ps.partial||0)+(ps.passWithWarning||0))+' warnings/partial &bull; '+((ps.fail||0)+(ps.blocked||0))+' root failures &bull; '+(ps.skippedPrerequisite||0)+' skipped</div><div style="display:flex;gap:6px;margin-top:10px;"><button class="r6p-btn secondary" onclick="r6pViewAppraisal(\''+r6pHtml(c.componentId)+'\')">View Appraisal</button><button class="r6p-btn secondary" onclick="r6pRetryAppraisal(\''+r6pHtml(c.componentId)+'\')">Retry Component</button>'+(c.sourceVmId?'<button class="r6p-btn secondary" onclick="r6pRetryVm(\''+r6pHtml(c.sourceVmId)+'\')">Retry VM</button>':'')+'</div></div>';}).join('');
  var completedNames={};
  (run.components||[]).forEach(function(c){completedNames[String(c.componentName||'').toLowerCase()]=true;});
  cards+=(R6P.components||[]).filter(function(c){return !completedNames[String(c.name||'').toLowerCase()];}).map(function(c){
    var live=String(run.currentComponent||'')===String(c.name||''),p=run.progress||{},status=live?'SCANNING':'QUEUED';
    return '<div style="border:1px solid #cbd5e1;border-top:4px solid '+(live?'#2563eb':'#94a3b8')+';border-radius:9px;background:#fff;padding:13px;">'
      +'<div style="display:flex;justify-content:space-between;gap:8px;"><strong>'+r6pHtml(c.name||'Component')+'</strong><span style="font-size:10px;color:'+(live?'#2563eb':'#64748b')+';font-weight:900;">'+status+'</span></div>'
      +'<div style="font-size:11px;color:#64748b;margin:6px 0;">Endpoint: '+r6pHtml(r6pComponentTarget(c)||'mapping required')+'</div>'
      +'<div style="font-size:11px;color:#334155;">'+(live?'Current probe: '+r6pHtml((p.currentProbe||'starting')+' '+(p.currentProbeName||''))+'<br>Completed probes: '+r6pHtml((p.completedProbes||0)+' / '+(p.totalProbes||20)):'Waiting for the preceding component to complete.')+'</div>'
      +'<div style="font-size:11px;color:#64748b;margin-top:8px;">Live evidence and readiness will populate automatically.</div>'
      +'</div>';
  }).join('');
  if(verdictRoot)verdictRoot.innerHTML=summary;
  root.innerHTML='<div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(290px,1fr));gap:12px;">'+cards+'</div>';
  if(failedRoot){failedRoot.innerHTML=r6pFailedChecksTable(run);}
  document.querySelectorAll('#r6p-scan-failed-checks').forEach(function(el,index){if(index>0)el.innerHTML='';});
  r6pPersistScanView(run);
};
window.r6pViewAppraisal=function(id){
  var c=R6P.structuredAppraisal&&R6P.structuredAppraisal.components&&R6P.structuredAppraisal.components.find(function(x){return x.componentId===id;}),drawer=document.getElementById('r6p-appraisal-drawer'),detail=document.getElementById('r6p-appraisal-detail');if(!c||!drawer||!detail)return;
  detail.innerHTML='<div style="display:flex;justify-content:space-between;align-items:flex-start;gap:8px;"><h2>'+r6pHtml(c.componentName)+'</h2><button class="r6p-btn secondary" onclick="r6pExportAppraisalCsv(\''+r6pHtml(c.componentId)+'\')">Export Result CSV</button></div><p><b>Verdict:</b> '+r6pHtml(c.componentVerdict)+' &nbsp; <b>Capture:</b> '+r6pHtml(c.captureRecommendation)+'</p><h3>Warnings</h3><ul>'+((c.warnings||[]).map(function(x){return '<li>'+r6pHtml(x.code)+': '+r6pHtml(x.message)+'</li>';}).join('')||'<li>None</li>')+'</ul><h3>Blockers</h3><ul>'+((c.blockers||[]).map(function(x){return '<li>'+r6pHtml(x.code)+': '+r6pHtml(x.message)+'</li>';}).join('')||'<li>None</li>')+'</ul><h3>Application paths</h3><pre>'+r6pHtml((c.applicationPaths||[]).join('\n')||'None discovered')+'</pre><h3>Probe Results</h3>'+((c.probes||[]).map(function(p){return '<details style="border:1px solid #e2e8f0;border-radius:6px;padding:8px;margin:6px 0;"><summary><b>'+p.probeId+' '+r6pHtml(p.probeName)+'</b> — '+p.status+' ('+p.durationMs+'ms, exit '+p.exitCode+(p.truncated?', truncated':'')+')</summary><div style="font-size:11px;margin:8px 0;">'+r6pHtml(p.remediation||'No remediation required.')+'</div><pre class="r6p-terminal" style="display:block;max-height:220px;">STDOUT\n'+r6pHtml(p.stdout||'')+'\n\nSTDERR\n'+r6pHtml(p.stderr||'')+'</pre></details>';}).join(''));
  drawer.style.display='block';
};
window.r6pCloseAppraisal=function(){var d=document.getElementById('r6p-appraisal-drawer');if(d)d.style.display='none';};
window.r6pRetryAppraisal=function(id){
  if(!R6P.scanRunId)return;var payload=r6pProductionScanPayload();
  var scanned=R6P.structuredAppraisal&&(R6P.structuredAppraisal.components||[]).find(function(x){return x.componentId===id;});
  var source=scanned&&(R6P.components||[]).find(function(c){return c.name===scanned.componentName;});
  var input=r6pInputConnectionFor(source||{});
  if(input.sshUser)payload.ssh.user=input.sshUser;
  if(input.sshKeyPath)payload.ssh.keyPath=input.sshKeyPath;
  payload.ssh.knownHostsFile=((document.getElementById('r6p-scan-known-hosts')||{}).value||payload.ssh.knownHostsFile||'').trim();
  fetch('/api/r6/scans/runs/'+encodeURIComponent(R6P.scanRunId)+'/components/'+encodeURIComponent(id)+'/retry',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ssh:payload.ssh})}).then(function(r){return r.json();}).then(function(d){if(!d.ok)throw new Error(d.error);r6pRefreshAppraisal();}).catch(function(e){alert('Retry failed: '+e.message);});
};
window.r6pRetryVm=function(vmId){
  if(!R6P.scanRunId||!vmId)return;var payload=r6pProductionScanPayload();
  fetch('/api/r6/scans/runs/'+encodeURIComponent(R6P.scanRunId)+'/vms/'+encodeURIComponent(vmId)+'/retry',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ssh:payload.ssh})}).then(function(r){return r.json();}).then(function(d){if(!d.ok)throw new Error(d.error);r6pRefreshAppraisal();}).catch(function(e){alert('VM retry failed: '+e.message);});
};
window.r6pRetryAllFailed=function(){
  if(!R6P.scanRunId){alert('Run a scan first.');return;}var payload=r6pProductionScanPayload();
  fetch('/api/r6/scans/runs/'+encodeURIComponent(R6P.scanRunId)+'/retry-failed',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ssh:payload.ssh})}).then(function(r){return r.json();}).then(function(d){if(!d.ok)throw new Error(d.error);r6pRefreshAppraisal();}).catch(function(e){alert('Retry failed: '+e.message);});
};
window.r6pVerifyReplaceHostKey=function(componentId){
  var component=R6P.structuredAppraisal&&(R6P.structuredAppraisal.components||[]).find(function(c){return c.componentId===componentId;});
  var probe=component&&(component.probes||[]).find(function(p){return p.errorCode==='SSH_HOST_KEY_CHANGED';});
  if(!component||!probe){alert('Host-key evidence is unavailable.');return;}
  var fingerprint=probe.newFingerprint||probe.hostFingerprint;if(!fingerprint){alert('A verified replacement fingerprint is required before this key can be changed.');return;}
  var known=((document.getElementById('r6p-scan-known-hosts')||{}).value||'').trim();
  r6pOpenHostIdentityPanel(component.sourceHost,component.sshPort||22,{componentId:componentId,vmId:component.sourceVmId,
    sshUser:((document.getElementById('r6p-scan-user')||{}).value||'').trim(),
    sshKeyPath:((document.getElementById('r6p-scan-key')||{}).value||'').trim(),knownHostsFile:known,
    onConnected:function(){r6pRetryVm(component.sourceVmId);}});
};

/* === SSH HOST IDENTITY / APPROVE FINGERPRINT WORKFLOW ===
   GOAL: when the scanner encounters an unknown or changed SSH host fingerprint, let the
   operator inspect it and either approve (first trust) or explicitly replace (changed key)
   it, persisting into the app-managed known_hosts file. Never disables host-key checking. */
R6P.hostIdentity={};
function r6pHostIdentityKey(host,port){return host+':'+(port||22);}
function r6pHostIdentityLogAppend(key,text){
  var s=R6P.hostIdentity[key]=R6P.hostIdentity[key]||{log:[]};
  var ts=new Date().toISOString().substr(11,8);
  s.log.push('['+ts+'] '+text);
}
function r6pHostIdentityLogText(key){var s=R6P.hostIdentity[key];return s&&s.log?s.log.join('\n'):'';}

window.r6pOpenHostIdentityPanel=function(host,port,opts){
  opts=opts||{};port=port||22;
  var key=r6pHostIdentityKey(host,port);
  var prior=R6P.hostIdentity[key];
  R6P.hostIdentity[key]={log:(prior&&prior.log)||[],host:host,port:port,componentId:opts.componentId||null,
    vmId:opts.vmId||null,sshUser:opts.sshUser||'',sshKeyPath:opts.sshKeyPath||'',
    knownHostsFile:opts.knownHostsFile||'',onConnected:opts.onConnected||null};
  r6pRenderHostIdentityOverlay(key);
  r6pRefreshHostIdentityStatus(key);
};

function r6pRenderHostIdentityOverlay(key){
  var existing=document.getElementById('r6p-host-identity-overlay');if(existing)existing.remove();
  var overlay=document.createElement('div');
  overlay.id='r6p-host-identity-overlay';
  overlay.style.cssText='position:fixed;inset:0;background:rgba(15,23,42,.55);z-index:9999;display:flex;align-items:center;justify-content:center;';
  overlay.innerHTML='<div id="r6p-a11y-live" aria-live="polite" style="position:absolute;width:1px;height:1px;overflow:hidden;"></div>'
    +'<div id="r6p-host-identity-card" style="background:#fff;border-radius:10px;max-width:560px;width:92%;max-height:88vh;overflow:auto;padding:18px;box-shadow:0 20px 60px rgba(0,0,0,.35);"></div>';
  overlay.addEventListener('click',function(e){if(e.target===overlay)r6pCloseHostIdentityPanel();});
  document.body.appendChild(overlay);
  r6pRenderHostIdentityCard(key);
}

window.r6pCloseHostIdentityPanel=function(){var el=document.getElementById('r6p-host-identity-overlay');if(el)el.remove();};

function r6pRenderHostIdentityCard(key){
  var card=document.getElementById('r6p-host-identity-card');if(!card)return;
  var s=R6P.hostIdentity[key]||{};
  var colors={UNKNOWN:'#d97706',TRUSTED:'#16a34a',CHANGED:'#dc2626',UNREACHABLE:'#64748b',CHECKING:'#64748b'};
  var color=colors[s.status]||'#64748b';
  var html='<div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:10px;">'
    +'<h3 style="margin:0;font-size:15px;">SSH Host Identity</h3>'
    +'<button onclick="r6pCloseHostIdentityPanel()" style="border:none;background:none;font-size:18px;cursor:pointer;color:#64748b;">&times;</button></div>';
  if(s.status==='UNKNOWN')html+='<div style="font-size:12px;color:#475569;margin-bottom:10px;">This VM has not been trusted yet. Review and approve its SSH fingerprint to persist trust in the managed known_hosts file.</div>';
  html+='<div style="font-family:monospace;font-size:12px;background:#f8fafc;border:1px solid #e2e8f0;border-radius:8px;padding:10px;margin-bottom:10px;">'
    +'Host: '+r6pHtml(s.host||'')+'<br>Port: '+r6pHtml(String(s.port||22))+'<br>Key type: '+r6pHtml(s.keyType||'—')
    +'<br>Fingerprint: '+r6pHtml(s.fingerprint||(s.status==='CHECKING'?'scanning...':'—'))+'</div>'
    +'<div style="margin-bottom:12px;"><b>Trust status: </b><span style="color:'+color+';font-weight:800;">'+r6pHtml(s.status||'CHECKING')+'</span></div>';
  if(s.status==='CHANGED'){
    html+='<div style="background:#fef2f2;border:1px solid #fecaca;border-radius:8px;padding:10px;margin-bottom:10px;font-size:12px;">'
      +'<b style="color:#dc2626;">⚠ SSH fingerprint changed</b><br>Previously trusted: '+r6pHtml(s.trustedFingerprint||'not reported')
      +'<br>Newly detected: '+r6pHtml(s.fingerprint||'—')+'<br>Host: '+r6pHtml(s.host)+':'+r6pHtml(String(s.port))
      +'<br>Detected at: '+r6pHtml(s.checkedAt||'')+'</div>'
      +'<button class="r6p-btn secondary" style="background:#dc2626;color:#fff;" id="r6p-replace-fp-btn" onclick="r6pReplaceHostFingerprint(\''+r6pHtml(key)+'\')">Replace Trusted Fingerprint</button>';
  }else if(s.status==='UNKNOWN'){
    html+='<button class="r6p-btn primary" id="r6p-approve-fp-btn" onclick="r6pApproveFingerprint(\''+r6pHtml(key)+'\')">Approve Fingerprint</button>'
      +'<div style="font-size:11px;color:#64748b;margin-top:5px;">Persist trust for this VM in the managed known_hosts file.</div>';
  }else if(s.status==='TRUSTED'){
    html+='<div style="color:#16a34a;font-weight:700;font-size:13px;">✓ Fingerprint approved</div><div style="font-size:11px;color:#64748b;">Stored in: '+r6pHtml(s.knownHostsFile||'')+'</div>';
  }else if(s.status==='UNREACHABLE'){
    html+='<div style="color:#64748b;font-size:12px;">'+r6pHtml(s.error||'Host is unreachable.')+'</div>'
      +'<button class="r6p-btn secondary" onclick="r6pRefreshHostIdentityStatus(\''+r6pHtml(key)+'\')">Retry Scan</button>';
  }
  html+='<div style="margin-top:14px;border-top:1px solid #e2e8f0;padding-top:10px;">'
    +'<div style="display:flex;justify-content:space-between;align-items:center;">'
    +'<b style="font-size:12px;cursor:pointer;" onclick="r6pToggleHostIdentityLog(\''+r6pHtml(key)+'\')">Operation Log '+(s.logOpen?'▾':'▸')+'</b>'
    +'<button class="r6p-btn secondary" id="r6p-copy-log-btn" onclick="r6pCopyHostIdentityLog(\''+r6pHtml(key)+'\')">Copy Log</button></div>'
    +'<pre id="r6p-host-identity-log" style="display:'+(s.logOpen?'block':'none')+';background:#0f172a;color:#a5f3fc;font-size:11px;padding:8px;border-radius:6px;max-height:160px;overflow:auto;margin-top:8px;white-space:pre-wrap;">'+r6pHtml(r6pHostIdentityLogText(key))+'</pre></div>';
  card.innerHTML=html;
}

window.r6pToggleHostIdentityLog=function(key){var s=R6P.hostIdentity[key];if(!s)return;s.logOpen=!s.logOpen;r6pRenderHostIdentityCard(key);};

window.r6pRefreshHostIdentityStatus=function(key){
  var s=R6P.hostIdentity[key];if(!s)return;
  s.status='CHECKING';r6pRenderHostIdentityCard(key);
  r6pHostIdentityLogAppend(key,'Scanning SSH host key for '+s.host+':'+s.port);
  var url='/api/r6/scans/known-hosts/status?host='+encodeURIComponent(s.host)+'&port='+encodeURIComponent(s.port)+(s.knownHostsFile?'&knownHostsFile='+encodeURIComponent(s.knownHostsFile):'');
  fetch(url).then(function(r){return r.json();}).then(function(d){
    if(!d.ok){s.status='UNREACHABLE';s.error=d.error;r6pHostIdentityLogAppend(key,'Scan failed: '+(d.error||'unknown error'));r6pRenderHostIdentityCard(key);return;}
    s.status=d.status;s.fingerprint=d.fingerprint;s.trustedFingerprint=d.trustedFingerprint;
    s.keyType=d.keyType;s.knownHostsFile=d.knownHostsFile;s.checkedAt=new Date().toISOString();
    if(d.status==='UNREACHABLE'){s.error=d.error;r6pHostIdentityLogAppend(key,'Scan failed: '+(d.error||'host unreachable'));}
    else{if(d.keyType)r6pHostIdentityLogAppend(key,d.keyType+' key discovered');if(d.fingerprint)r6pHostIdentityLogAppend(key,'Fingerprint: '+d.fingerprint);r6pHostIdentityLogAppend(key,'Trust status: '+d.status);}
    r6pRenderHostIdentityCard(key);
  }).catch(function(e){s.status='UNREACHABLE';s.error=e.message;r6pHostIdentityLogAppend(key,'Scan failed: '+e.message);r6pRenderHostIdentityCard(key);});
};

window.r6pApproveFingerprint=function(key){
  var s=R6P.hostIdentity[key];if(!s||!s.fingerprint)return;
  var btn=document.getElementById('r6p-approve-fp-btn');if(btn){btn.disabled=true;btn.textContent='Approving...';}
  r6pHostIdentityLogAppend(key,'User approved fingerprint');
  r6pHostIdentityLogAppend(key,'Managed known_hosts file locked');
  fetch('/api/r6/scans/known-hosts/approve',{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({host:s.host,port:s.port,fingerprint:s.fingerprint,knownHostsFile:s.knownHostsFile,vmId:s.vmId})})
    .then(function(r){return r.json();}).then(function(d){
      if(!d.ok)throw new Error(d.error||'approval failed');
      s.status='TRUSTED';s.knownHostsFile=d.knownHostsFile;
      r6pHostIdentityLogAppend(key,'Host key persisted successfully');
      r6pHostIdentityLogAppend(key,'File permissions verified: 0600');
      r6pRenderHostIdentityCard(key);
      r6pRetryHostIdentityConnection(key);
    }).catch(function(e){
      r6pHostIdentityLogAppend(key,'Approval failed: '+e.message);
      if(btn){btn.disabled=false;btn.textContent='Approve Fingerprint';}
      r6pRenderHostIdentityCard(key);
    });
};

window.r6pReplaceHostFingerprint=function(key){
  var s=R6P.hostIdentity[key];if(!s||!s.fingerprint)return;
  if(!confirm('Replace the trusted SSH fingerprint for '+s.host+':'+s.port+'?\n\nOnly do this after independently verifying the new fingerprint with the infrastructure owner.\n\nOld: '+(s.trustedFingerprint||'not reported')+'\nNew: '+s.fingerprint))return;
  var btn=document.getElementById('r6p-replace-fp-btn');if(btn){btn.disabled=true;btn.textContent='Replacing...';}
  r6pHostIdentityLogAppend(key,'User confirmed fingerprint replacement');
  fetch('/api/r6/scans/known-hosts/verify-and-replace',{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({approved:true,host:s.host,port:s.port,expectedFingerprint:s.fingerprint,knownHostsFile:s.knownHostsFile,vmId:s.vmId})})
    .then(function(r){return r.json();}).then(function(d){
      if(!d.ok)throw new Error(d.error||'replacement failed');
      s.status='TRUSTED';s.knownHostsFile=d.knownHostsFile;
      r6pHostIdentityLogAppend(key,'Trusted fingerprint replaced');
      r6pRenderHostIdentityCard(key);
      r6pRetryHostIdentityConnection(key);
    }).catch(function(e){
      r6pHostIdentityLogAppend(key,'Replacement failed: '+e.message);
      if(btn){btn.disabled=false;btn.textContent='Replace Trusted Fingerprint';}
      r6pRenderHostIdentityCard(key);
    });
};

function r6pRetryHostIdentityConnection(key){
  var s=R6P.hostIdentity[key];if(!s)return;
  r6pHostIdentityLogAppend(key,'Retrying SSH connection with strict verification');
  fetch('/api/r6/scans/known-hosts/connection-test',{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({host:s.host,port:s.port,user:s.sshUser,keyPath:s.sshKeyPath,knownHostsFile:s.knownHostsFile})})
    .then(function(r){return r.json();}).then(function(d){
      r6pHostIdentityLogAppend(key,d.connectionResult==='PASS'?'SSH host identity verified':'Connection test did not pass: '+(d.summary||d.errorCode||''));
      r6pHostIdentityLogAppend(key,'Connection test: '+(d.connectionResult||'UNKNOWN'));
      r6pRenderHostIdentityCard(key);
      if(d.connectionResult==='PASS'&&typeof s.onConnected==='function')s.onConnected();
    }).catch(function(e){r6pHostIdentityLogAppend(key,'Connection retry failed: '+e.message);r6pRenderHostIdentityCard(key);});
}

window.r6pCopyHostIdentityLog=function(key){
  var text=r6pHostIdentityLogText(key);
  var btn=document.getElementById('r6p-copy-log-btn');
  function done(){
    if(btn){var original='Copy Log';btn.textContent='Copied ✓';setTimeout(function(){if(btn)btn.textContent=original;},2000);}
    var live=document.getElementById('r6p-a11y-live');if(live)live.textContent='Log copied to clipboard';
  }
  if(navigator.clipboard&&navigator.clipboard.writeText){
    navigator.clipboard.writeText(text).then(done).catch(function(){r6pCopyLogFallback(text,done);});
  }else{
    r6pCopyLogFallback(text,done);
  }
};

function r6pCopyLogFallback(text,done){
  var ta=document.createElement('textarea');
  ta.value=text;ta.style.position='fixed';ta.style.left='-9999px';
  document.body.appendChild(ta);ta.focus();ta.select();
  try{document.execCommand('copy');done();}catch(e){alert('Copy failed. Select and copy the log manually.');}
  document.body.removeChild(ta);
}

window.r6pCheckSelectedComponentHostIdentity=function(){
  var comps=(R6P.components||[]);
  var sel=document.getElementById('r6p-scan-comp');
  var idx=sel?sel.value:'';
  var c=(idx&&idx!=='__all__')?comps[Number(idx)]:comps[0];
  var target=c&&r6pComponentTarget(c);
  if(!target){alert('Select a mapped component first.');return;}
  var host='';try{host=new URL(target.indexOf('://')>=0?target:'ssh://'+target).hostname;}catch(e){host=target.replace(/^[a-z][a-z0-9+.-]*:\/\//i,'').split('/')[0].split(':')[0];}
  r6pOpenHostIdentityPanel(host,22,{
    sshUser:((document.getElementById('r6p-scan-user')||{}).value||'').trim(),
    sshKeyPath:((document.getElementById('r6p-scan-key')||{}).value||'').trim(),
    knownHostsFile:((document.getElementById('r6p-scan-known-hosts')||{}).value||'').trim()});
};
/* === END SSH HOST IDENTITY WORKFLOW === */
window.r6pRunAllLiveScans=function(){
  var sel=document.getElementById('r6p-scan-comp');
  var out=document.getElementById('r6p-scan-out');
  var comps=(R6P.components||[]).filter(function(c){return r6pComponentTarget(c);});
  if(!sel||!comps.length||R6P.allScanRunning)return;
  /* Capture credentials once. Stage bodies can be refreshed while a batch is
     running; rereading a replaced input used to silently fall back to root. */
  var batchCredentials={
    user:String(((document.getElementById('r6p-scan-user')||{}).value)||'').trim(),
    key:String(((document.getElementById('r6p-scan-key')||{}).value)||'').trim()
  };
  if(!/^[a-z_][a-z0-9_.-]*$/i.test(batchCredentials.user)){
    if(out){out.style.display='block';out.textContent='Enter a valid SSH username before scanning all components.';}
    return;
  }
  if(!batchCredentials.key){
    if(out){out.style.display='block';out.textContent='Enter an SSH private key path before scanning all components.';}
    return;
  }
  R6P.allScanRunning=true;
  var button=document.getElementById('r6p-live-scan-btn');
  if(button){button.disabled=true;button.textContent='Scanning all components...';}
  if(out){out.style.display='block';out.textContent='== All components live scan: '+comps.length+' component(s) ==\n';}
  var index=0,passed=0,failed=0;
  function next(){
    if(index>=comps.length){
      sel.value='__all__';
      if(out){out.textContent+='\n== All components scan complete: '+passed+' passed, '+failed+' failed ==\n';out.scrollTop=out.scrollHeight;}
      R6P.allScanRunning=false;
      if(button){button.disabled=false;button.innerHTML='&#9654; Run Live Scan';}
      var stage8=document.getElementById('r6p-body-8');
      var stage8Inner=stage8&&stage8.querySelector('.r6p-stage-body-inner');
      if(stage8Inner)stage8Inner.innerHTML=r6pContent(8);
      return;
    }
    sel.value=String(index);
    if(out){out.textContent+='\n['+(index+1)+'/'+comps.length+'] '+comps[index].name+'\n';out.scrollTop=out.scrollHeight;}
    index++;
    r6pRunLiveScan(function(ok){if(ok)passed++;else failed++;next();},true,batchCredentials);
  }
  next();
};
window.r6pRunLiveScan=function(done,appendMode,credentials){
  var sel=document.getElementById('r6p-scan-comp');
  var idx=sel?sel.value:'';
  if(idx==='__all__'){r6pRunAllLiveScans();return;}
  var comps6=(R6P.components||[]).filter(function(c){return r6pComponentTarget(c);});
  var comp=comps6[idx];
  var out=document.getElementById('r6p-scan-out');
  if(!comp){if(out){out.style.display='block';out.textContent='Select a component with a FLEX target IP first (choose a Business System in Step 1).';}if(typeof done==='function')done(false);return;}
  var user=String((credentials&&credentials.user)||((document.getElementById('r6p-scan-user')||{}).value)||'').trim();
  var key=String((credentials&&credentials.key)||((document.getElementById('r6p-scan-key')||{}).value)||'').trim();
  var endpoint=r6pParseSshTarget(r6pComponentTarget(comp),comp);
  if(!endpoint){if(out){out.style.display='block';out.textContent='Invalid SSH target for '+comp.name+'. Set a valid FLEX hostname or IP in Step 1.';}if(typeof done==='function')done(false);return;}
  if(!/^[a-z_][a-z0-9_.-]*$/i.test(user)){if(out){out.style.display='block';out.textContent='Invalid SSH username.';}if(typeof done==='function')done(false);return;}
  key=String(key).trim().replace(/^~(?=\/|$)/,'$HOME');
  if(!/^(\$HOME|\/)[a-z0-9_./ -]+$/i.test(key)){if(out){out.style.display='block';out.textContent='Invalid SSH key path.';}if(typeof done==='function')done(false);return;}
  var remote=[
    'echo "-- hostnamectl / uname --"; hostnamectl 2>/dev/null || true; uname -a',
    'echo "-- open ports --"; (ss -tulpn 2>/dev/null || netstat -tulpn 2>/dev/null || true)',
    'echo "-- running services --"; systemctl --type=service --state=running 2>/dev/null | head -30 || true',
    'echo "-- top processes --"; ps aux --sort=-%mem 2>/dev/null | head -30',
    'echo "-- disk usage (df -h) --"; df -h 2>/dev/null',
    'echo "-- block devices (lsblk) --"; lsblk 2>/dev/null || true',
    'echo "-- mounts (/etc/fstab) --"; cat /etc/fstab 2>/dev/null || true',
    'echo "-- cron jobs --"; crontab -l 2>/dev/null || true; ls /etc/cron.d/ 2>/dev/null || true',
    'echo "-- known app/db config files --"; find /etc -maxdepth 3 -type f 2>/dev/null | grep -E "nginx|apache|mysql|postgres|mongo|redis|env" | head -30 || true',
    'echo "-- app paths (non-system files) --"; find /opt /srv /var/www /home -maxdepth 4 -type f 2>/dev/null | grep -vE "\\.cache|\\.log$" | head -50 || true'
  ].join('; ');
  var keyArg=key.indexOf('$HOME')===0?'\"'+key+'\"':r6pShellQuote(key);
  var cmd='echo '+r6pShellQuote('== Guest dependency scan: '+comp.name+' ('+endpoint.host+':'+endpoint.port+') ==')+'\n'
    +'ssh -i '+keyArg+' -p '+endpoint.port+' -o BatchMode=yes -o StrictHostKeyChecking=no '
    +'-o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null '
    +'-o ConnectTimeout=8 '+r6pShellQuote(user+'@'+endpoint.host)+' '+r6pShellQuote(remote);
  if(out){out.style.display='block';if(!appendMode)out.textContent='';}
  R6P.depScan=R6P.depScan||{};
  R6P.depScan[comp.name]={ip:endpoint.host,sshPort:endpoint.port,sourceEndpoint:endpoint.source,startedAt:new Date().toISOString(),rawLog:'',status:'RUNNING',completed:false};
  var url='/api/stream/run-cmd?cmd='+encodeURIComponent(cmd);
  var es=new EventSource(url);
  es.onmessage=function(e){
    if(e.data==='[DONE]'){es.close();return;}
    if(e.data.indexOf('[EXIT')===0){
      var ok=/\[EXIT 0\]/.test(e.data);
      R6P.depScan[comp.name].status=ok?'COMPLETE':'FAILED';
      R6P.depScan[comp.name].completed=ok;
      R6P.depScan[comp.name].finishedAt=new Date().toISOString();
      if(out){out.textContent+=(ok?'✓ Live scan completed successfully.':'✗ Live scan failed: '+e.data)+'\n';out.scrollTop=out.scrollHeight;}
      es.close();if(typeof done==='function')done(ok);return;
    }
    if(out){out.textContent+=e.data+'\n';out.scrollTop=out.scrollHeight;}
    R6P.depScan[comp.name].rawLog+=e.data+'\n';
  };
  es.onerror=function(){R6P.depScan[comp.name].status='FAILED';R6P.depScan[comp.name].completed=false;es.close();if(out)out.textContent+='[stream error]\n';if(typeof done==='function')done(false);};
};
window.r6pExportDepScan=function(){
  var sel=document.getElementById('r6p-scan-comp');
  var comps6=(R6P.components||[]).filter(function(c){return r6pComponentTarget(c);});
  if(sel&&sel.value==='__all__'){
    var reports=comps6.map(function(c){
      var scan=(R6P.depScan&&R6P.depScan[c.name])||{};
      return {component:c.name,sourceEndpoint:r6pComponentTarget(c),sshHost:scan.ip||null,sshPort:scan.sshPort||null,status:scan.status||'NOT_RUN',completed:scan.completed===true,scannedAt:scan.startedAt||null,finishedAt:scan.finishedAt||null,raw:scan.rawLog||''};
    });
    var allBlob=new Blob([JSON.stringify({generatedAt:new Date().toISOString(),components:reports},null,2)],{type:'application/json'});
    var allLink=document.createElement('a');allLink.href=URL.createObjectURL(allBlob);allLink.download='app_dependency_report_all_components.json';
    document.body.appendChild(allLink);allLink.click();document.body.removeChild(allLink);return;
  }
  var comp=comps6[sel?sel.value:''];
  if(!comp||!R6P.depScan||!R6P.depScan[comp.name]){alert('Run the live scan first.');return;}
  var scan=R6P.depScan[comp.name];
  var report={component:comp.name,sourceEndpoint:r6pComponentTarget(comp),sshHost:scan.ip,sshPort:scan.sshPort,status:scan.status,completed:scan.completed,scannedAt:scan.startedAt,finishedAt:scan.finishedAt||null,raw:scan.rawLog};
  var blob=new Blob([JSON.stringify(report,null,2)],{type:'application/json'});
  var a=document.createElement('a');a.href=URL.createObjectURL(blob);
  a.download='app_dependency_report_'+comp.name.replace(/\s+/g,'_')+'.json';
  document.body.appendChild(a);a.click();document.body.removeChild(a);
};

window.r6pRunClassify=function(){
  var sel=document.getElementById('r6p-classify-comp');
  var idx=sel?sel.value:'';
  var comps7=(R6P.components||[]).filter(function(c){return r6pComponentTarget(c);});
  var comp=comps7[idx];
  var out=document.getElementById('r6p-classify-out');
  if(!comp){if(out){out.style.display='block';out.textContent='Select a component with a FLEX target IP first (choose a Business System in Step 1).';}return;}
  var user=(document.getElementById('r6p-classify-user')||{}).value||'root';
  var key=(document.getElementById('r6p-classify-key')||{}).value||'~/.ssh/id_rsa';
  var ip=r6pComponentTarget(comp);
  ['app_code','config_template','secret_candidate','log_file','database_data','excluded_file'].forEach(function(k){
    var el=document.getElementById('r6p-classify-count-'+k);if(el){el.textContent='Checking...';el.style.color='#0369a1';}
  });
  var tmpf='/tmp/r6_classify_'+Date.now()+'.txt';
  var cmd='ssh -i '+key+' -o StrictHostKeyChecking=no -o ConnectTimeout=8 '+user+'@'+ip+' "find /opt /srv /var/www /home -maxdepth 6 -type f 2>/dev/null" > '+tmpf+' 2>&1\n'
    +'app=0; cfg=0; sec=0; log=0; db=0; exc=0\n'
    +'while IFS= read -r f; do\n'
    +'  case "$f" in\n'
    +'    *.log|*/log/*) log=$((log+1));;\n'
    +'    *.pem|*.key|*id_rsa*|*.crt|*secret*|*.env) sec=$((sec+1));;\n'
    +'    *.conf|*.yaml|*.yml|*.ini|*.cfg|*.properties) cfg=$((cfg+1));;\n'
    +'    */var/lib/mysql/*|*/var/lib/postgresql/*|*.sql|*.sqlite|*.db) db=$((db+1));;\n'
    +'    *.tmp|*.cache|*~|*.bak) exc=$((exc+1));;\n'
    +'    *) app=$((app+1));;\n'
    +'  esac\n'
    +'done < '+tmpf+'\n'
    +'echo "CLASSIFY:app_code:$app"\n'
    +'echo "CLASSIFY:config_template:$cfg"\n'
    +'echo "CLASSIFY:secret_candidate:$sec"\n'
    +'echo "CLASSIFY:log_file:$log"\n'
    +'echo "CLASSIFY:database_data:$db"\n'
    +'echo "CLASSIFY:excluded_file:$exc"\n'
    +'rm -f '+tmpf;
  if(out){out.style.display='block';out.textContent='$ Checking '+comp.name+' ('+ip+')...\n';}
  var url='/api/stream/run-cmd?cmd='+encodeURIComponent(cmd);
  var es=new EventSource(url);
  es.onmessage=function(e){
    if(e.data==='[DONE]'||e.data.indexOf('[EXIT')===0){es.close();return;}
    if(out){out.textContent+=e.data+'\n';out.scrollTop=out.scrollHeight;}
    var m=e.data.match(/^CLASSIFY:([a-z_]+):(\d+)$/);
    if(m){var el=document.getElementById('r6p-classify-count-'+m[1]);if(el){el.textContent=m[2]+' file'+(m[2]==='1'?'':'s');el.style.color=m[2]==='0'?'#94a3b8':'#0f172a';el.style.fontWeight='700';}}
  };
  es.onerror=function(){es.close();if(out)out.textContent+='[stream error]\n';};
};

function shellescape(s){return "'"+s.replace(/'/g,"'\\''")+"'";}

/* ── OpenCenter Stage 2 import override ── */
window.openCenterImportFromR6=function(){
  /* Read new state first, fall back to legacy key */
  var raw=localStorage.getItem('appsContainerRefactorOutput')||localStorage.getItem('r6OpenCenterHandoffBundle');
  if(!raw){
    var badge=document.getElementById('clf-st-2');
    if(badge){badge.textContent='Awaiting Bundle';badge.className='ocqs-status ocqs-s-idle';}
    return;
  }
  var data;
  try{data=JSON.parse(raw);}catch(e){console.error('openCenterImportFromR6: invalid JSON',e);return;}

  /* Normalise — handle both new appsContainerRefactorOutput and old bundle format */
  var bsName=data.businessSystemName||data.businessSystem||'Unknown';
  var captureMethod=data.captureMethod||'SMART_SNAPSHOT_CAPTURE';
  var cloudStatus=data.cloudNativeStatus||data.importStatus||'CLOUD_NATIVE_READY';
  var cluster=data.targetCluster||'rackspace-flex/flex-prod-k8s';
  var ns=data.namespace||bsName.toLowerCase().replace(/\s+/g,'-')+'-prod';
  var workloads=data.workloads||[];
  var extSvc=data.externalServices||[];
  var warns=(data.warnings||[]).length;
  var blockers=(data.blockers||[]).length;
  var pkgContents=data.packageContents||{};
  var isCompat=captureMethod==='FULL_SNAPSHOT_COMPATIBILITY_CONTAINER';
  var isBlocked=blockers>0||cloudStatus==='BLOCKED';

  /* Update status badge on Step 2 card */
  var st2=document.getElementById('clf-st-2');
  if(st2){st2.textContent=isBlocked?'Blocked':'Ready to Validate';st2.className='ocqs-status '+(isBlocked?'ocqs-s-failed':'ocqs-s-running');}

  /* Update main pane status badge */
  var pst=document.getElementById('s2opencenter-status');
  if(pst){pst.textContent=isBlocked?'Blocked — Fix R6 issues':'R6 Bundle Ready';pst.className='gov-status-badge '+(isBlocked?'status-failed':'status-running');}

  /* Build package contents table */
  var pkgDefs=[
    {f:'opencenter_import_manifest.json',req:'Required'},
    {f:'k8s/',req:'Required'},{f:'helm/',req:'Required'},{f:'kustomize/',req:'Required'},{f:'flux/',req:'Required'},
    {f:'Dockerfile',req:'Recommended'},{f:'image_build_plan.yaml',req:'Required'},{f:'app_capture_manifest.json',req:'Required'},
    {f:'externalization_plan.yaml',req:'Required'},{f:'container_readiness_report.json',req:'Required'},
    {f:'container_readiness_report.md',req:'Recommended'},{f:'compatibility_warnings.json',req:'Conditional'}
  ];
  var pkgTable='<table style="width:100%;border-collapse:collapse;font-size:11px;">'
    +'<thead><tr style="background:#f8fafc;"><th style="padding:6px 10px;text-align:left;border-bottom:2px solid #e2e8f0;color:#0369a1;font-size:10px;text-transform:uppercase;">File/Folder</th>'
    +'<th style="padding:6px 10px;text-align:left;border-bottom:2px solid #e2e8f0;color:#0369a1;font-size:10px;text-transform:uppercase;">Required?</th>'
    +'<th style="padding:6px 10px;text-align:left;border-bottom:2px solid #e2e8f0;color:#0369a1;font-size:10px;text-transform:uppercase;">Status</th>'
    +'</tr></thead><tbody>';
  pkgDefs.forEach(function(p){
    var isCond=p.req==='Conditional';
    var raw_st=pkgContents[p.f]||(isCond?(isCompat?'found':'not_required'):'missing');
    var stMap={'found':['#dcfce7','#16a34a','Found'],'missing':['#fee2e2','#dc2626','Missing'],'not_required':['#f1f5f9','#64748b','Not Required'],'warning':['#fef3c7','#d97706','Warning']};
    var st=stMap[raw_st]||stMap.missing;
    var reqBg=p.req==='Required'?'#fee2e2':p.req==='Recommended'?'#fef3c7':'#f1f5f9';
    var reqFg=p.req==='Required'?'#dc2626':p.req==='Recommended'?'#d97706':'#64748b';
    pkgTable+='<tr style="border-bottom:1px solid #f1f5f9;">'
      +'<td style="padding:5px 10px;font-family:monospace;font-weight:600;">'+p.f+'</td>'
      +'<td style="padding:5px 10px;"><span style="background:'+reqBg+';color:'+reqFg+';padding:2px 7px;border-radius:999px;font-size:10px;font-weight:700;">'+p.req+'</span></td>'
      +'<td style="padding:5px 10px;"><span style="background:'+st[0]+';color:'+st[1]+';padding:2px 7px;border-radius:999px;font-size:10px;font-weight:700;">'+st[2]+'</span></td></tr>';
  });
  pkgTable+='</tbody></table>';

  /* Build summary panel */
  var summaryHTML='<div style="background:#f0fdf4;border:1.5px solid #86efac;border-radius:8px;padding:14px;margin-bottom:12px;">'
    +'<div style="font-size:12px;font-weight:800;color:#166534;margin-bottom:8px;">Imported from Apps Container Refactor Engine</div>'
    +'<div style="display:grid;grid-template-columns:repeat(3,1fr);gap:8px;font-size:12px;">'
    +'<div><div style="color:#64748b;font-size:10px;font-weight:700;text-transform:uppercase;margin-bottom:2px;">Business System</div><div style="font-weight:700;color:#0f172a;">'+bsName+'</div></div>'
    +'<div><div style="color:#64748b;font-size:10px;font-weight:700;text-transform:uppercase;margin-bottom:2px;">Source Platform</div><div style="font-weight:700;color:#0369a1;">FLEX</div></div>'
    +'<div><div style="color:#64748b;font-size:10px;font-weight:700;text-transform:uppercase;margin-bottom:2px;">Capture Method</div><div style="font-weight:700;color:'+(isCompat?'#7c3aed':'#16a34a')+';">'+(isCompat?'Full Snapshot':'Smart Snapshot')+'</div></div>'
    +'<div><div style="color:#64748b;font-size:10px;font-weight:700;text-transform:uppercase;margin-bottom:2px;">Cloud-Native Status</div><div style="font-weight:700;color:'+(isCompat?'#7c3aed':'#16a34a')+';">'+cloudStatus.replace(/_/g,' ')+'</div></div>'
    +'<div><div style="color:#64748b;font-size:10px;font-weight:700;text-transform:uppercase;margin-bottom:2px;">Target Cluster</div><div style="font-weight:700;color:#0f172a;font-size:11px;">'+cluster+'</div></div>'
    +'<div><div style="color:#64748b;font-size:10px;font-weight:700;text-transform:uppercase;margin-bottom:2px;">Namespace</div><div style="font-weight:700;color:#0f172a;">'+ns+'</div></div>'
    +'<div><div style="color:#64748b;font-size:10px;font-weight:700;text-transform:uppercase;margin-bottom:2px;">Workloads</div><div style="font-weight:700;">'+workloads.map(function(w){return w.name||w;}).join(', ')||'—'+'</div></div>'
    +'<div><div style="color:#64748b;font-size:10px;font-weight:700;text-transform:uppercase;margin-bottom:2px;">External Services</div><div style="font-weight:700;">'+extSvc.map(function(s){return s.name||s;}).join(', ')||'None'+'</div></div>'
    +'<div><div style="color:#64748b;font-size:10px;font-weight:700;text-transform:uppercase;margin-bottom:2px;">Import Status</div><div style="font-weight:700;color:'+(isBlocked?'#dc2626':'#16a34a')+'">'+(isBlocked?'BLOCKED — fix R6 issues':'Ready to Validate')+'</div></div>'
    +(warns?'<div style="grid-column:1/-1;"><div style="color:#64748b;font-size:10px;font-weight:700;text-transform:uppercase;margin-bottom:2px;">Warnings</div><div style="color:#d97706;font-weight:700;">'+warns+' warning'+(warns!==1?'s':'')+'</div></div>':'')
    +'</div></div>';

  /* Inject into Stage 2 card — replace the "Accepted package contents" static grid */
  var step2=document.getElementById('clf-step-2');
  if(step2){
    var existing=document.getElementById('r6p-oc-import-panel');
    if(existing)existing.remove();
    var panel=document.createElement('div');
    panel.id='r6p-oc-import-panel';
    panel.style.cssText='margin:0 0 12px;';
    panel.innerHTML=summaryHTML
      +'<div style="font-size:10px;font-weight:800;color:#0369a1;text-transform:uppercase;letter-spacing:1px;margin:10px 0 6px;">Package Contents Validation</div>'
      +pkgTable
      +'<div style="display:flex;gap:8px;flex-wrap:wrap;margin-top:12px;">'
      +'<button onclick="openCenterValidateImport()" style="background:#0369a1;color:#fff;border:none;border-radius:6px;padding:7px 14px;font-size:12px;font-weight:700;cursor:pointer;">Validate Package</button>'
      +(isBlocked?'<button disabled style="background:#f1f5f9;color:#94a3b8;border:1px solid #e2e8f0;border-radius:6px;padding:7px 14px;font-size:12px;font-weight:700;cursor:not-allowed;" title="Fix R6 blockers first">Send to OpenCenter — Blocked</button>'
        :'<button onclick="openCenterMockGenerate()" style="background:#16a34a;color:#fff;border:none;border-radius:6px;padding:7px 14px;font-size:12px;font-weight:700;cursor:pointer;">Send to OpenCenter</button>')
      +'</div>';
    var uploadDiv=step2.querySelector('[style*="display:flex;gap:8px;flex-wrap:wrap;margin-bottom:12px;"]');
    if(uploadDiv)uploadDiv.parentNode.insertBefore(panel,uploadDiv.nextSibling);
    else step2.appendChild(panel);
  }

  /* Update legacy oc-import-status box if it exists */
  var legacyBox=document.getElementById('oc-import-status');
  if(legacyBox){legacyBox.innerHTML='<strong style="color:#16a34a;">Imported from Apps Container Refactor Engine</strong> — '+bsName+' — '+cloudStatus.replace(/_/g,' ');}

  /* Persist merged state */
  data.importedAt=new Date().toISOString();
  data.source='APPS_to_Container_Refactor_Engine';
  localStorage.setItem('openCenterImportState',JSON.stringify(data));
};

/* Auto-init: MutationObserver fires when pane becomes visible */
(function(){
  function tryInit(){var p=document.getElementById('s2r6ace-pane');if(p&&p.style.display!=='none'&&!p.getAttribute('data-r6p-init')){p.setAttribute('data-r6p-init','1');r6pInit();}}
  var pane=document.getElementById('s2r6ace-pane');
  if(pane){new MutationObserver(function(){tryInit();}).observe(pane,{attributes:true,attributeFilter:['style']});}
  document.addEventListener('click',function(e){if(e.target.closest('[data-sub="s2r6ace"]'))setTimeout(tryInit,300);});
  var orig=window.activateSub;if(typeof orig==='function'){window.activateSub=function(panes,id){orig(panes,id);if(id==='s2r6ace')setTimeout(tryInit,150);};}
  setTimeout(tryInit,500);
})();

/* OpenRC parser — handles v2 password, v3 password, v3 app credential */
function r6pParseOpenRC(text){
  var vars={};
  text.split('\n').forEach(function(line){
    /* strip comments */
    line=line.replace(/#.*/,'').trim();
    var m=line.match(/^(?:export\s+)?([A-Z0-9_]+)\s*=\s*["']?([^"'\n]*)["']?\s*$/);
    if(m)vars[m[1]]=m[2].trim();
  });
  /* variable expansion */
  Object.keys(vars).forEach(function(k){
    vars[k]=vars[k].replace(/\$\{?([A-Z0-9_]+)\}?/g,function(_,v){return vars[v]||'';});
  });
  /* detect auth type */
  var authType=(vars.OS_AUTH_TYPE||'').toLowerCase();
  var isAppCred=authType==='v3applicationcredential'||!!vars.OS_APPLICATION_CREDENTIAL_ID;
  var isV2=(!vars.OS_IDENTITY_API_VERSION||vars.OS_IDENTITY_API_VERSION==='2'||vars.OS_IDENTITY_API_VERSION==='2.0')&&!isAppCred;
  return {vars:vars,isAppCred:isAppCred,isV2:isV2};
}

/* Fill Stage 0 r6p-c-* credential fields */
window.r6pImportOpenRC=function(evt){
  var file=evt.target.files[0];if(!file)return;
  var reader=new FileReader();
  reader.onload=function(e){
    var p=r6pParseOpenRC(e.target.result);
    var v=p.vars;
    function set(id,val){var el=document.getElementById(id);if(el&&val!=null&&val!=='')el.value=val;}

    set('r6p-c-authurl', v.OS_AUTH_URL);
    set('r6p-c-region',  v.OS_REGION_NAME);
    set('r6p-c-proj',    v.OS_PROJECT_ID||v.OS_TENANT_ID||v.OS_PROJECT_NAME);

    /* show username/password fields if v2/password auth detected */
    var pwRow=document.getElementById('r6p-c-pw-row');
    var dt=document.getElementById('r6p-c-authtype');
    if(p.isAppCred){
      if(dt){dt.value='appcred';r6pAuthTypeChange('appcred');}
      set('r6p-c-credid',  v.OS_APPLICATION_CREDENTIAL_ID);
      set('r6p-c-secret',  v.OS_APPLICATION_CREDENTIAL_SECRET);
      r6pShowCredResult('cloud','Detected: v3 Application Credential. Fields populated.','#16a34a');
    } else {
      if(dt){dt.value='password';r6pAuthTypeChange('password');}
      set('r6p-c-username',v.OS_USERNAME);
      set('r6p-c-password',v.OS_PASSWORD);
      set('r6p-c-domain',  v.OS_USER_DOMAIN_NAME||v.OS_PROJECT_DOMAIN_NAME||'rackspace_cloud_domain');
      var authVer=p.isV2?'v2 Password':'v3 Password';
      r6pShowCredResult('cloud','Detected: '+authVer+'. Fields populated. Consider an Application Credential for automation.','#d97706');
    }
    /* set region dropdown if detected */
    var reg=v.OS_REGION_NAME;
    if(reg){var rs=document.getElementById('r6p-c-region');if(rs){for(var i=0;i<rs.options.length;i++){if(rs.options[i].value===reg){rs.selectedIndex=i;break;}}}}

    /* save to R6P state (no secret stored) */
    R6P.creds.cloud.authUrl=v.OS_AUTH_URL||'';
    R6P.creds.cloud.region=v.OS_REGION_NAME||'';
    R6P.creds.cloud.projectId=v.OS_PROJECT_ID||v.OS_TENANT_ID||'';
    R6P.creds.cloud.credId=v.OS_APPLICATION_CREDENTIAL_ID||'';
    R6P.creds.cloud.status='configured';
    /* persist non-secret fields */
    r6pSaveCredCache();
    /* also fill clf-* and ocqs-* for OpenCenter stage */
    r6pFillClfFields(v,p.isAppCred);
  };
  reader.readAsText(file);
};

function r6pFillClfFields(v,isAppCred){
  function set(id,val){var el=document.getElementById(id);if(el&&val)el.value=val;}
  set('clf-auth-url',v.OS_AUTH_URL);
  set('clf-region',v.OS_REGION_NAME);
  set('clf-proj',v.OS_PROJECT_ID||v.OS_TENANT_ID);
  set('clf-domain',v.OS_USER_DOMAIN_NAME||v.OS_PROJECT_DOMAIN_NAME);
  if(isAppCred){set('clf-cred-id',v.OS_APPLICATION_CREDENTIAL_ID);set('clf-cred-sec',v.OS_APPLICATION_CREDENTIAL_SECRET);}
  else{set('clf-username',v.OS_USERNAME);set('clf-password',v.OS_PASSWORD);}
  set('ocqs-authUrl',v.OS_AUTH_URL);set('ocqs-region',v.OS_REGION_NAME);
  if(typeof ocqsUpdate==='function')ocqsUpdate();
}

window.r6pAuthTypeChange=function(val){
  var pw=document.getElementById('r6p-c-pw-fields');
  var ac=document.getElementById('r6p-c-appcred-fields');
  if(pw)pw.style.display=val==='appcred'?'none':'block';
  if(ac)ac.style.display=val==='appcred'?'block':'none';
};

function r6pShowCredResult(block,msg,color){
  var el=document.getElementById('r6p-'+block+'-result');
  if(el){el.textContent=msg;el.style.color=color;}
}

/* Legacy clfImportOpenRC — kept for OpenCenter stage buttons */
window.clfImportOpenRC=function(evt){
  var file=evt&&evt.target&&evt.target.files[0];if(!file)return;
  var reader=new FileReader();
  reader.onload=function(e){
    var p=r6pParseOpenRC(e.target.result);
    r6pFillClfFields(p.vars,p.isAppCred);
  };
  reader.readAsText(file);
};

/* Install button map */
var R6ACE_INSTALL={'opencenter version':'git clone https://github.com/opencenter-cloud/openCenter-cli.git && cd openCenter-cli && mise trust && mise install && mise run build && sudo cp ./bin/opencenter /usr/local/bin/opencenter && opencenter version','kubectl version --client':'curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && kubectl version --client','opentofu version':'curl -sSLo /tmp/opentofu.zip https://github.com/opentofu/opentofu/releases/download/v1.8.0/tofu_1.8.0_linux_amd64.zip && cd /tmp && unzip -o opentofu.zip && sudo mv tofu /usr/local/bin/opentofu && opentofu version','flux --version || true':'curl -s https://fluxcd.io/install.sh | sudo bash && flux --version','git --version':'sudo apt-get update && sudo apt-get install -y git','curl --version':'sudo apt-get update && sudo apt-get install -y curl','jq --version':'sudo apt-get update && sudo apt-get install -y jq','helm version':'curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash','yq --version':'sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && sudo chmod +x /usr/local/bin/yq && yq --version','kustomize version':'curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash && sudo mv kustomize /usr/local/bin/kustomize && kustomize version'};
window.r6aceRunInstall=function(did,cmdId,outId){var d=document.getElementById(did);if(d)d.remove();var out=document.getElementById(outId),cEl=document.getElementById(cmdId);if(!out||!cEl)return;var cmd=cEl.textContent.trim();var ic=R6ACE_INSTALL[cmd];if(!ic)return;out.textContent='Installing...\n';out.style.borderColor='#134e4a';var url='/api/stream/run-cmd?cmd='+encodeURIComponent(ic);var es=new EventSource(url);es.onmessage=function(e){if(e.data!=='[DONE]'){out.textContent+=e.data+'\n';out.scrollTop=out.scrollHeight;}else{es.close();setTimeout(function(){r6pRunCmd(cmdId,outId);},500);}};es.onerror=function(){out.textContent+='[install error]\n';es.close();};};

/* GitOps credentials card: two-way sync with the OpenCenter Production panel state (ocqp).
   Must never read/write ocqs_state (Quickstart demo panel) - R6 deploys real business
   systems and has to target the same GitOps repo/cluster as the real production cluster. */
window.r6pGitAuthToggle = function(){
  var a = (document.getElementById('r6p-git-auth')||{}).value || 'ssh';
  var sr = document.getElementById('r6p-git-ssh-row'), tr = document.getElementById('r6p-git-token-row');
  if (sr) sr.style.display = (a === 'ssh') ? '' : 'none';
  if (tr) tr.style.display = (a === 'token') ? '' : 'none';
};
window.r6pLooksLikeGitDir = function(s){
  if (!s || s.indexOf('/') !== 0) return false;
  /* reject bare UUIDs / non-path values that have leaked into this field before */
  if (/^\/?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s)) return false;
  return true;
};
window.r6pGitLoad = function(){
  try {
    var st = JSON.parse(localStorage.getItem('ocqp_state') || '{}');
    var set = function(id, v){ var el = document.getElementById(id); if (el && v) el.value = v; };
    set('r6p-git-repo', st.gitRepo); set('r6p-git-branch', st.gitBranch);
    set('r6p-git-sshkey', st.sshKey); set('r6p-git-token', st.tokVal);
    if (st.gitopsFolder && r6pLooksLikeGitDir(st.gitopsFolder)) {
      set('r6p-git-localdir', st.gitopsFolder);
      R6P.creds.opencenter.gitDir = st.gitopsFolder;
    } else {
      if (st.gitopsFolder) { try { st.gitopsFolder = ''; localStorage.setItem('ocqp_state', JSON.stringify(st)); } catch(e){} }
      var badEl = document.getElementById('r6p-git-localdir'); if (badEl) badEl.value = '';
      if (typeof r6pAutoDetectGitDir === 'function') { r6pAutoDetectGitDir(); }
    }
    var sel = document.getElementById('r6p-git-auth');
    if (sel && st.gitAuth) sel.value = st.gitAuth;
    r6pGitAuthToggle();
    var b = document.getElementById('r6p-git-badge');
    if (b && st.gitRepo){ b.textContent = 'Configured'; b.style.color = '#15803d'; }
    /* The real production cluster's org/cluster (set in the ocqp panel) determines the
       GitOps overlay path applications/overlays/<cluster>/managed-services/<slug> -
       without this, R6 silently falls back to a hardcoded placeholder cluster ref. */
    if (st.org && st.cluster) { R6P.creds.opencenter.clusterRef = st.org + '/' + st.cluster; }
  } catch(e){}
};
window.r6pAutoDetectGitDir = function(){
  var cmd = 'opencenter cluster describe --output yaml 2>/dev/null | awk -F": " \'/^git_dir:/{print $2; exit}\'';
  var es = new EventSource('/api/stream/run-cmd?cmd=' + encodeURIComponent(cmd));
  var out = '';
  es.onmessage = function(e){
    if (e.data === '[DONE]' || e.data.indexOf('[EXIT') === 0){
      es.close();
      var dir = out.trim();
      if (dir && typeof r6pLooksLikeGitDir === 'function' && r6pLooksLikeGitDir(dir)){
        var el = document.getElementById('r6p-git-localdir');
        /* CLI-detected value is authoritative - overwrite any stale/bad cached value */
        if (el) el.value = dir;
        R6P.creds.opencenter.gitDir = dir;
        if (typeof r6pGitSave === 'function') r6pGitSave();
      }
      return;
    }
    out += e.data;
  };
  es.onerror = function(){ es.close(); };
};
window.r6pGitSave = function(){
  if (typeof r6pSaveCredsServer === 'function') r6pSaveCredsServer();
  var v = function(id){ var el = document.getElementById(id); return el ? el.value.trim() : ''; };
  var st = {};
  try { st = JSON.parse(localStorage.getItem('ocqp_state') || '{}'); } catch(e){}
  st.gitRepo = v('r6p-git-repo'); st.gitBranch = v('r6p-git-branch') || 'main';
  st.gitAuth = v('r6p-git-auth') || 'ssh'; st.sshKey = v('r6p-git-sshkey') || '~/.ssh/id_rsa';
  if (v('r6p-git-token')) st.tokVal = v('r6p-git-token');
  var localDir = v('r6p-git-localdir');
  if (localDir) { st.gitopsFolder = localDir; R6P.creds.opencenter.gitDir = localDir; }
  try { localStorage.setItem('ocqp_state', JSON.stringify(st)); } catch(e){}
  if (st.org && st.cluster) { R6P.creds.opencenter.clusterRef = st.org + '/' + st.cluster; }
  var stEl = document.getElementById('r6p-git-status');
  if (stEl){
    if (!st.gitRepo){ stEl.textContent = '\u2717 repository URL required'; stEl.style.color = '#dc2626'; return; }
    stEl.textContent = '\u2713 saved - shared with OpenCenter Production (Stage 2)'; stEl.style.color = '#15803d';
  }
  var b = document.getElementById('r6p-git-badge');
  if (b){ b.textContent = st.gitRepo ? 'Configured' : 'Not Configured'; b.style.color = st.gitRepo ? '#15803d' : '#94a3b8'; }
};
setTimeout(function(){ if (document.getElementById('r6p-git-repo')) r6pGitLoad(); }, 400);


(function(){
  if(window.__r6pFlaskRestartHotkeyInstalled)return;
  window.__r6pFlaskRestartHotkeyInstalled=true;
  function ensurePanel(){
    var panel=document.getElementById('r6p-flask-restart-panel');
    if(panel)return panel;
    panel=document.createElement('div');
    panel.id='r6p-flask-restart-panel';
    panel.style.cssText='display:none;position:fixed;right:18px;bottom:18px;z-index:10080;background:#ffffff;border:1px solid #bfdbfe;box-shadow:0 18px 45px rgba(15,23,42,.20);border-radius:14px;padding:14px 16px;min-width:280px;font-family:system-ui,-apple-system,Segoe UI,sans-serif;color:#0f172a;';
    panel.innerHTML='<div style="display:flex;justify-content:space-between;align-items:flex-start;gap:12px;margin-bottom:8px;"><div><div style="font-weight:900;font-size:14px;">Flask Control</div><div style="font-size:11px;color:#64748b;">Ctrl + Shift + R opened this panel.</div></div><button id="r6p-flask-restart-close" style="border:0;background:#f1f5f9;color:#334155;border-radius:8px;padding:3px 8px;cursor:pointer;">×</button></div><button id="r6p-flask-restart-btn" class="r6p-btn primary" style="width:100%;padding:9px 12px;font-size:12px;">Restart Flask</button><div id="r6p-flask-restart-status" style="font-size:11px;color:#64748b;margin-top:8px;line-height:1.4;">Restart without rerunning letsmove.sh.</div>';
    document.body.appendChild(panel);
    document.getElementById('r6p-flask-restart-close').onclick=function(){panel.style.display='none';};
    document.getElementById('r6p-flask-restart-btn').onclick=r6pRestartFlask;
    return panel;
  }
  window.r6pShowFlaskRestart=function(){ensurePanel().style.display='block';};
  window.r6pRestartFlask=function(){
    var panel=ensurePanel(),btn=document.getElementById('r6p-flask-restart-btn'),st=document.getElementById('r6p-flask-restart-status');
    panel.style.display='block';if(btn)btn.disabled=true;if(st){st.textContent='Restart requested… Flask will reload in a moment.';st.style.color='#0369a1';}
    fetch('/api/dev/restart-flask',{method:'POST',headers:{'Accept':'application/json'}}).then(function(r){return r.json().catch(function(){return{};}).then(function(d){if(!r.ok||!d.ok)throw new Error(d.error||('HTTP '+r.status));return d;});}).then(function(){
      if(st){st.textContent='Restart scheduled. Reloading when Flask comes back…';st.style.color='#15803d';}
      setTimeout(function(){window.location.reload();},2200);
    }).catch(function(e){if(st){st.textContent='Restart failed: '+e.message;st.style.color='#dc2626';}if(btn)btn.disabled=false;});
  };
  document.addEventListener('keydown',function(e){
    if(e.ctrlKey&&e.shiftKey&&String(e.key||'').toLowerCase()==='r'){
      e.preventDefault();e.stopPropagation();r6pShowFlaskRestart();
    }
  },true);
})();
